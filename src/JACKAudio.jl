__precompile__()

module JACKAudio

using SampleTypes
using Base.Libc: malloc, free

export JACKClient, sources, sinks, seekavailable

# TODO: Logging is segfaulting when used inside the precompiled callback function
# using Logging

# Logging.configure(level=DEBUG)

include("libjack.jl")

# the ringbuffer size will be this times sizeof(float) rounded up to the nearest
# power of two
const RINGBUF_SAMPLES = 131072
# we'll advance the ringbuf read pointer by this many samples whenever we
# detect an overflow.
const OVERFLOW_ADVANCE = 8192

function __init__()
    global const process_cb = cfunction(process, Cint, (NFrames, Ptr{Ptr{Void}}))
    global const shutdown_cb = cfunction(shutdown, Void, (Ptr{JACKClient}, ))
    global const info_handler_cb = cfunction(info_handler, Void, (Cstring, ))
    global const error_handler_cb = cfunction(error_handler, Void, (Cstring, ))
    
    
    ccall((:jack_set_info_function, :libjack), Void, (Ptr{Void},),
        info_handler_cb)
    ccall((:jack_set_error_function, :libjack), Void, (Ptr{Void},),
        error_handler_cb)
end

function error_handler(msg)
    println("libjack: ERROR: $(bytestring(msg))")

    nothing
end

function info_handler(msg)
    println("libjack: $(bytestring(msg))")

    nothing
end

"""Represents a single-channel stream to or from JACK. Each port has a JACK
ringbuffer to get data in and out of the process callback and a julia RingBuffer
object that can be used for additional buffering. One important difference is
that if the jack ringbuffer fills up it can't be written to, but the Julia
RingBuffer maintains the last N samples"""
immutable JACKPort
    name::ASCIIString
    ptr::PortPtr
    jackbuf::RingBufPtr
    
    function JACKPort(client, name, porttype)
        ptr = jack_port_register(client, name, JACK_DEFAULT_AUDIO_TYPE, porttype, 0)
        if isnullptr(ptr)
            error("Failed to create port for $name")
        end
        
        bufptr = jack_ringbuffer_create(RINGBUF_SAMPLES * sizeof(JACKSample))
        if isnullptr(bufptr)
            jack_port_unregister(client, ptr)
            error("Failed to create ringbuffer for $name")
        end
        
        new(name, ptr, bufptr)
    end
end

# JACKSource and JACKSink defs are almost identical, so DRY it out with some
# metaprogramming magic
for (T, Super, porttype) in
        [(:JACKSource, :SampleSource, :PortIsInput),
         (:JACKSink, :SampleSink, :PortIsOutput)]
    """Represents a multi-channel stream, so it contains multiple jack ports
    that are considered synchronized, i.e. you read or write to all of them
    as a group. There can be multiple JACKSources and JACKSinks in a JACKClient,
    and all the sources and sinks in a client get updated by the same `process`
    method."""
    @eval immutable $T{N, SR} <: $Super{N, SR, JACKSample}
        name::ASCIIString
        client::ClientPtr
        clientname::ASCIIString
        ports::Vector{JACKPort}
        ringcondition::Condition # used to synchronize any in-progress transations
        
        function $T(client::ClientPtr, clientname, name)
            ports = JACKPort[]
            for ch in 1:N
                pname = portname(name, N, ch)
                push!(ports, JACKPort(client, pname, $porttype))
            end
            
            # TODO: switch to a mutable type, add finalizer, null out pointers
            # after closing/freeing them
            new(name, client, clientname, ports, Condition())
        end
    end
    
    @eval $T(client, clientname, name, nchannels) =
        $T{nchannels, Int(jack_get_sample_rate(client))}(client, clientname, name)
        
    @eval function Base.close(s::$T)
        for port in s.ports
            jack_port_unregister(s.client, port.ptr)
            jack_ringbuffer_free(port.jackbuf)
        end
    end
    
    @eval function Base.show(io::IO, s::$T)
        print(io, $T, "(\"$(s.name)\", $(length(s.ports)))")
    end
end
    
"""Generate the name of an individual port. This is what shows up in a JACK port
list"""
function portname(name, totalchans, chan)
    suffix = totalchans == 1 ? "" : "_$chan"
    string(name, suffix)
end

"""A `JACKClient` represents a connection to the JACK server. It can contain
multiple `JACKSource`s and `JACKSink`s. It is automatically activated when it is
constructed, so the sources and sinks are available for reading and writing,
respectively."""
type JACKClient
    name::ASCIIString
    ptr::ClientPtr
    sources::Vector{JACKSource}
    sinks::Vector{JACKSink}
    # this is memory allocated separately with malloc that is used to give the
    # process callback all the pointers it needs for the source/sink ports and
    # ringbuffers
    portptrs::Ptr{Ptr{Void}}
    callback::Base.SingleAsyncWork

    # this constructor takes a list of name, channelcount pairs
    function JACKClient{T1 <: Tuple, T2 <: Tuple}(
            name::AbstractString="Julia",
            sources::Vector{T1}=[("In", 2)],
            sinks::Vector{T2}=[("Out", 2)];
            connect=true, active=true)
        status = Ref{Cint}(Failure)
        clientptr = jack_client_open(name, 0, status)
        if isnullptr(clientptr)
            error("Failure opening JACK Client: ", status_str(status[]))
        end
        if status[] & ServerStarted
            # info("Started JACK Server")
        end
        if status[] & NameNotUnique
            name = bytestring(jack_get_client_name(clientptr))
            info("Given name not unique, renamed to ", name)
        end
        # println("Opened JACK Client with status: ", status_str(status[]))
        
        # we malloc 2*nsources + 2*nsinks + 3, because for each source and sink
        # we have the port pointer and the ringbuf pointer, the source and sink
        # lists are null-terminated, and we need to include the callback handle
        nsources = sum([p[2] for p in sources])
        nsinks = sum([p[2] for p in sinks])
        nptrs = 2nsources + 2nsinks + 3
        # TODO: we can switch this malloc and unsafe_store business
        # to an array we push! to
        portptrs = Ptr{Ptr{Void}}(malloc(nptrs*sizeof(Ptr{Void})))
        if isnullptr(portptrs)
            jack_client_close(clientptr)
            error("Failure allocating memory for JACK client \"$name\"")
        end
            
        # for now we leave the callback field uninitialized because we need the
        # client reference to build the callback closure
        client = new(name, clientptr, JACKSource[], JACKSink[], portptrs)
        
        # TODO: break out the source/sink addition to separate functions
        # initialize the sources and sinks
        ptridx = 1
        try
            for sourceargs in sources
                source = JACKSource(clientptr, name, sourceargs[1], sourceargs[2])
                push!(client.sources, source)
                # copy pointers to our flat pointer list that we'll give to the callback
                for port in source.ports
                    unsafe_store!(portptrs, port.ptr, ptridx)
                    unsafe_store!(portptrs, port.jackbuf, ptridx+1)
                    ptridx += 2
                end
            end
        catch
            close(client)
            rethrow()
        end
        # list of sources is null-terminated
        unsafe_store!(portptrs, C_NULL, ptridx)
        ptridx += 1
        
        try
            for sinkargs in sinks
                sink = JACKSink(clientptr, name, sinkargs[1], sinkargs[2])
                push!(client.sinks, sink)
                # copy pointers to our flat pointer list that we'll give to the callback
                for port in sink.ports
                    unsafe_store!(portptrs, port.ptr, ptridx)
                    unsafe_store!(portptrs, port.jackbuf, ptridx+1)
                    ptridx += 2
                end
            end
        catch
            close(client)
            rethrow()
        end
        # list of sinks is null-terminated
        unsafe_store!(portptrs, C_NULL, ptridx)
        ptridx += 1
        
        client.callback = Base.SingleAsyncWork(data -> managebuffers(client))
        
        # and finally we store the callback handle so the JACK process callback
        # can trigger the managebuffers function to run in the julia context
        unsafe_store!(portptrs, client.callback.handle, ptridx)
        
        jack_set_process_callback(clientptr, process_cb, portptrs)
        jack_on_shutdown(clientptr, shutdown_cb, pointer_from_objref(client))
        
        # useful when debugging, because you'll see errors. not sure how safe it
        # is though
        # process(128, portptrs)
        
        finalizer(client, close)
        
        if active
            activate(client)
            if connect
                autoconnect(client)
            end
        end
        
        client
    end
end

SampleTypes.samplerate(client::JACKClient) =
    Int(jack_get_sample_rate(client.ptr))

# also allow constructing just by giving channel counts
JACKClient(name::AbstractString,
            sourcecount::Integer, sinkcount::Integer; kwargs...) =
    JACKClient(name, [("In", sourcecount)], [("Out", sinkcount)]; kwargs...)
    
JACKClient(sourcecount::Integer, sinkcount::Integer; kwargs...) =
    JACKClient("Julia", [("In", sourcecount)], [("Out", sinkcount)]; kwargs...)
    
function Base.show(io::IO, client::JACKClient)
    print(io, "JACKClient(\"$(client.name)\", [")
    sources = ASCIIString["(\"$(source.name)\", $(nchannels(source)))" for source in client.sources]
    sinks = ASCIIString["(\"$(sink.name)\", $(nchannels(sink)))" for sink in client.sinks]
    print_joined(io, sources, ", ")
    print(io, "], [")
    print_joined(io, sinks, ", ")
    print(io, "])")
end

function Base.close(client::JACKClient)
    if !isnullptr(client.ptr)
        deactivate(client)
    end
    if !isnullptr(client.portptrs)
        free(client.portptrs)
        client.portptrs = C_NULL
    end
    for i in length(client.sources):-1:1
        close(client.sources[i])
        deleteat!(client.sources, i)
    end
    for i in length(client.sinks):-1:1
        close(client.sinks[i])
        deleteat!(client.sinks, i)
    end
    if !isnullptr(client.ptr)
        status = jack_client_close(client.ptr)
        client.ptr = C_NULL
        if status != Int(Success)
            error("Error closing client $(client.name): $(status_str(status))")
        end
    end
    
    nothing
end

sources(client::JACKClient) = client.sources
sinks(client::JACKClient) = client.sinks

# TODO: julia PR to extend Base.isnull rather than using isnullptr
isnullptr(ptr::Ptr) = Ptr{Void}(ptr) == C_NULL
isnullptr(ptr::Cstring) = Ptr{Cchar}(ptr) == C_NULL

"""Connect the given client to the physical input/output ports, by just matching
them up sequentially"""
function autoconnect(client::JACKClient)
    # look for physical output ports (the output from the sound card is an input
    # for us)
    ports = jack_get_ports(client.ptr, Ptr{Cchar}(C_NULL), Ptr{Cchar}(C_NULL),
        PortIsPhysical | PortIsOutput)
    if !isnullptr(ports)
        idx = 1
        for stream in client.sources
            for ch in 1:length(stream.ports)
                isnullptr(unsafe_load(ports, idx)) && break
                localportname = string(client.name, ":",
                                       portname(stream.name, length(stream.ports), ch))
                jack_connect(client.ptr, unsafe_load(ports, idx), bytestring(localportname))
                
                idx += 1
            end
            isnullptr(unsafe_load(ports, idx)) && break
        end
        jack_free(ports)
    end
    ports = jack_get_ports(client.ptr, Ptr{Cchar}(C_NULL), Ptr{Cchar}(C_NULL),
        PortIsPhysical | PortIsInput)
    if !isnullptr(ports)
        idx = 1
        for stream in client.sinks
            for ch in 1:length(stream.ports)
                isnullptr(unsafe_load(ports, idx)) && break
                localportname = string(client.name, ":",
                                       portname(stream.name, length(stream.ports), ch))
                jack_connect(client.ptr, bytestring(localportname), unsafe_load(ports, idx))
                
                idx += 1
            end
            isnullptr(unsafe_load(ports, idx)) && break
        end
        jack_free(ports)
    end
end

"""Connect the client's sinks to its sources, mostly useful for testing"""
function selfconnect(client::JACKClient)
    sinknames = []
    sourcenames = []
    for sink in client.sinks
        N = length(sink.ports)
        for i in 1:N
            push!(sinknames, string(client.name, ":", portname(sink.name, N, i)))
        end
    end
    for source in client.sources
        N = length(source.ports)
        for i in 1:N
            push!(sourcenames, string(client.name, ":", portname(source.name, N, i)))
        end
    end
    
    for (src, dest) in zip(sinknames, sourcenames)
        jack_connect(client.ptr, src, dest)
    end

end

function Base.connect(sink::JACKSink, source::JACKSource)
    for (sinkport, sourceport) in zip(sink.ports, source.ports)
        sinkportname = string(sink.clientname, ":", sinkport.name)
        sourceportname = string(source.clientname, ":", sourceport.name)
        jack_connect(sink.client, sinkportname, sourceportname)
    end
end

# this should only get called during construction
function activate(client::JACKClient)
    status = ccall((:jack_activate, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error activating client $(client.name): $(status_str(status))")
    end
    
    nothing
end

# this should only get called when closing the client
function deactivate(client::JACKClient)
    status = ccall((:jack_deactivate, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error deactivating client $(client.name): $(status_str(status))")
    end
    
    nothing
end


# TODO: handle multiple writer situation
# handle writes from a buffer with matching channel count and sample rate. Up/Down
# mixing and resampling should be the responsibility of SampleTypes.jl
function Base.write{N, SR}(sink::JACKSink{N, SR}, buf::SampleBuf{N, SR, JACKSample})
    # a JACKSink{N. SR} should always have N set of pointers, by construction
    @assert length(sink.ports) == N
    nbytes = Csize_t(nframes(buf) * sizeof(JACKSample))
    bytesleft = ones(Csize_t, N) * nbytes
    chanptrs = Ptr{JACKSample}[channelptr(buf, ch) for ch in 1:N]
    
    for (ch, port) in enumerate(sink.ports)
        n = jack_ringbuffer_write(port.jackbuf, chanptrs[ch], bytesleft[ch])
        bytesleft[ch] -= n
        chanptrs[ch] += n
    end
    while any(x -> x > 0, bytesleft)
        # wait to be notified that some space has freed up in the ringbuf
        wait(sink.ringcondition)
        for (ch, port) in enumerate(sink.ports)
            n = jack_ringbuffer_write(port.jackbuf, chanptrs[ch], bytesleft[ch])
            bytesleft[ch] -= n
            chanptrs[ch] += n
        end
    end
    
    # by now we know we've written the whole length of the buffer
    nframes(buf)
end

function overflowed(source::JACKSource)
    for port in source.ports
        if jack_ringbuffer_write_space(port.jackbuf) < sizeof(JACKSample)
            return true
        end
    end
    
    false
end

function min_read_space(source::JACKSource)
    minspace = typemax(Csize_t)
    for port in source.ports
        minspace = min(minspace, jack_ringbuffer_read_space(port.jackbuf))
    end
    
    minspace
end

"""advances the read pointer of the ring buffer without actually reading the
data"""
function ringbuf_read_advance(source::JACKSource, amount)
    for port in source.ports
        jack_ringbuffer_read_advance(port.jackbuf, amount)
    end
end

# TODO: handle multiple reader situation
function Base.read!{N, SR}(source::JACKSource{N, SR}, buf::SampleBuf{N, SR, JACKSample})
    bytesleft = Csize_t(nframes(buf) * sizeof(JACKSample))
    chanptrs = Ptr{JACKSample}[channelptr(buf, ch) for ch in 1:N]
    
    # do the first read immediately
    minspace = min_read_space(source)
    nbytes = sampalign(min(minspace, bytesleft))
    for (ch, port) in enumerate(source.ports)
        jack_ringbuffer_read(port.jackbuf, chanptrs[ch], nbytes)
        chanptrs[ch] += nbytes
    end
    bytesleft -= nbytes
    
    # now we wait to be notified that there's new data to read
    while bytesleft > 0
        # wait to be notified that new samples are available in the ringbuf
        wait(source.ringcondition)
        minspace = min_read_space(source)
        nbytes = sampalign(min(minspace, bytesleft))
        for (ch, port) in enumerate(source.ports)
            jack_ringbuffer_read(port.jackbuf, chanptrs[ch], nbytes)
            chanptrs[ch] += nbytes
        end
        bytesleft -= nbytes
    end
    
    # by now we know we've read the whole length of the buffer
    nframes(buf)
end

function seekavailable(source::JACKSource)
    minspace = navailable(source)
    ringbuf_read_advance(source, minspace)
end

navailable(source::JACKSource) = sampalign(min_read_space(source))

function Base.wait(source::JACKSource)
    navailable(source) > 0 && return nothing
    wait(source.ringcondition)
end

# This gets called from a separate thread, so it is VERY IMPORTANT that it not
# allocate any memory or JIT compile when it's being run. Here be segfaults.
function process(nframes, portptrs)
    nbytes::Csize_t = nframes * sizeof(JACKSample)
    
    ptridx = 1
    # handle sources
    
    # we want to find the minimum amount of space in any ringbuffer, so we keep
    # all the channels synchronized even if a channel is overflowing
    minbytes = nbytes
    while !isnullptr(unsafe_load(portptrs, ptridx))
        ringbuf = unsafe_load(portptrs, ptridx + 1)
        ptridx += 2
        minbytes = min(minbytes, jack_ringbuffer_write_space(ringbuf))
    end
    # make sure we only write whole samples
    minbytes = sampalign(minbytes)
    
    # rewind back to the beginning for the actual writes
    ptridx = 1
    
    while !isnullptr(unsafe_load(portptrs, ptridx))
        source = unsafe_load(portptrs, ptridx)
        ringbuf = unsafe_load(portptrs, ptridx + 1)
        ptridx += 2
    
        buf = jack_port_get_buffer(source, nframes)
        jack_ringbuffer_write(ringbuf, buf, minbytes)
    end
    # skip over the null terminator
    ptridx += 1
    
    sinkidx = ptridx
    
    # handle sinks
    
    minbytes = nbytes
    # we want to find the minimum number of bytes available in any ringbuffer,
    # so we keep all the channels synchronized
    while !isnullptr(unsafe_load(portptrs, ptridx))
        ringbuf = unsafe_load(portptrs, ptridx + 1)
        ptridx += 2
        minbytes = min(minbytes, jack_ringbuffer_read_space(ringbuf))
    end
    # make sure we only read whole samples
    minbytes = sampalign(minbytes)
    
    # rewind back to the beginning of the sinks
    ptridx = sinkidx
    while !isnullptr(unsafe_load(portptrs, ptridx))
        sink = unsafe_load(portptrs, ptridx)
        ringbuf = unsafe_load(portptrs, ptridx + 1)
        ptridx += 2
        
        buf = jack_port_get_buffer(sink, nframes)
        # we know we're able to read at least minbytes
        jack_ringbuffer_read(ringbuf, buf, minbytes)
        if minbytes != nbytes
            memset(buf+minbytes, 0, nbytes - minbytes)
        end
    end
    # skip over the null terminator
    ptridx += 1
        
    handle = unsafe_load(portptrs, ptridx)
    
    # notify the managebuffers, which will get called with a reference to
    # this client
    ccall(:uv_async_send, Void, (Ptr{Void},), handle)
    
    Cint(0)
end

"""Returns the largest x <= value s.t. x has the given alignment (in bytes)"""
align{T<:Unsigned}(value::T, alignment::Integer) = value & ~(T(alignment-1))
sampalign(value) = align(value, sizeof(JACKSample))

# this callback gets called from within the Julia event loop, but is triggered
# by every `process` call. It bumps any tasks waiting to read or write
function managebuffers(client)
    for source in client.sources
        # if we've overflowed, advance the read head
        if overflowed(source)
            advance = min(OVERFLOW_ADVANCE, min_read_space(source))
            ringbuf_read_advance(source, advance)
        end
        notify(source.ringcondition)
    end
    
    for sink in client.sinks
        notify(sink.ringcondition)
    end
end

function shutdown(arg)
    nothing
end

memset(buf, val, count) = ccall(:memset, Ptr{Void},
    (Ptr{Void}, Cint, Csize_t),
    buf, 0, count)


end # module
