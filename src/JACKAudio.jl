__precompile__()

module JACKAudio

using SampleTypes
using Base.Libc: malloc, free

export JackClient

# TODO: Logging is segfaulting when used inside the precompiled callback function
# using Logging

# Logging.configure(level=DEBUG)

include("jack_types.jl")

# the ringbuffer size will be this times sizeof(float) rounded up to the nearest
# power of two
const RINGBUF_SAMPLES = 131072

function __init__()
    global const process_cb = cfunction(process, Cint, (NFrames, Ptr{Ptr{Void}}))
    global const shutdown_cb = cfunction(shutdown, Void, (Ptr{JackClient}, ))
    global const info_handler_cb = cfunction(info_handler, Void, (Cstring, ))
    global const error_handler_cb = cfunction(error_handler, Void, (Cstring, ))
    
    
    ccall((:jack_set_info_function, :libjack), Void, (Ptr{Void},),
        info_handler_cb)
    ccall((:jack_set_error_function, :libjack), Void, (Ptr{Void},),
        error_handler_cb)
end

function error_handler(msg)
    println("libjack: $(bytestring(msg))")

    nothing
end

function info_handler(msg)
    println("libjack: $(bytestring(msg))")

    nothing
end

immutable PortPointers
    port::PortPtr
    ringbuf::RingBufPtr
end

# JackSource and JackSink defs are almost identical, so DRY it out with some
# metaprogramming magic
for (T, Super, porttype) in [(:JackSource, :SampleSource, :PortIsInput),
                             (:JackSink, :SampleSink, :PortIsOutput)]
    @eval immutable $T{N, SR} <: $Super{N, SR, JackSample}
        name::ASCIIString
        ptrs::Vector{PortPointers}
        ringcondition::Condition # used to synchronize any in-progress transations
        
        function $T(client::ClientPtr, name::AbstractString)
            ptrs = PortPointers[]
            for ch in 1:N
                suffix = N == 1 ? "" : "_$ch"
                ptr = jack_port_register(client, string(name, suffix), JACK_DEFAULT_AUDIO_TYPE, $porttype, 0)
                if ptr == C_NULL
                    error("Failed to create port for $name$suffix")
                end
                
                bufptr = jack_ringbuffer_create(RINGBUF_SAMPLES * sizeof(JackSample))
                if bufptr == C_NULL
                    jack_port_unregister(client, ptr)
                    error("Failed to create ringbuffer for $name$suffix")
                end
                push!(ptrs, PortPointers(ptr, bufptr))
            end
            
            new(name, ptrs, Condition())
        end
    end
    
    @eval $T(client, name, nchannels) =
        $T{nchannels, Int(jack_get_sample_rate(client))}(client, name)
        
    @eval function Base.close(s::$T, client::ClientPtr)
        for ptr in s.ptrs
            jack_port_unregister(client, ptr.port)
            jack_ringbuffer_free(ptr.ringbuf)
        end
    end
    
    @eval function Base.show(io::IO, s::$T)
        print(io, $T, "(\"$(s.name)\", $(length(s.ptrs)))")
    end
end

type JackClient
    name::ASCIIString
    ptr::ClientPtr
    sources::Vector{JackSource}
    sinks::Vector{JackSink}
    # this is memory allocated separately with malloc that is used to give the
    # process callback all the pointers it needs for the source/sink ports and
    # ringbuffers
    portptrs::Ptr{Ptr{Void}}
    callback::Base.SingleAsyncWork

    # this constructor takes a list of name, channelcount pairs
    function JackClient{T1 <: Tuple, T2 <: Tuple}(name::AbstractString,
            sources::Vector{T1}, sinks::Vector{T2})
        status = Ref{Cint}(Failure)
        clientptr = jack_client_open(name, 0, status)
        if clientptr == C_NULL
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
        portptrs = Ptr{Ptr{Void}}(malloc(nptrs*sizeof(Ptr{Void})))
        if portptrs == C_NULL
            jack_client_close(clientptr)
            error("Failure allocating memory for Jack client \"$name\"")
        end
            
        # for now we leave the callback field uninitialized because we need the
        # client reference to build the callback closure
        client = new(name, clientptr, JackSource[], JackSink[], portptrs)
        
        # initialize the sources and sinks
        ptridx = 1
        try
            for sourceargs in sources
                source = JackSource(clientptr, sourceargs[1], sourceargs[2])
                push!(client.sources, source)
                # copy pointers to our flat pointer list that we'll give to the callback
                for ptr in source.ptrs
                    unsafe_store!(portptrs, ptr.port, ptridx)
                    unsafe_store!(portptrs, ptr.ringbuf, ptridx+1)
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
                sink = JackSink(clientptr, sinkargs[1], sinkargs[2])
                push!(client.sinks, sink)
                # copy pointers to our flat pointer list that we'll give to the callback
                for ptr in sink.ptrs
                    unsafe_store!(portptrs, ptr.port, ptridx)
                    unsafe_store!(portptrs, ptr.ringbuf, ptridx+1)
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
        activate(client)
        
        client
    end
end

JackClient(name::AbstractString, sourcecount::Integer, sinkcount::Integer) =
    JackClient(name, [("In", sourcecount)], [("Out", sinkcount)])
    
JackClient(sourcecount::Integer, sinkcount::Integer) =
    JackClient("Julia", sourcecount, sinkcount)
    
JackClient(name::AbstractString) = JackClient(name, 2, 2)

JackClient() = JackClient("Julia")

function Base.show(io::IO, client::JackClient)
    print(io, "JackClient(\"$(client.name)\", [")
    sources = ASCIIString["(\"$(source.name)\", $(nchannels(source)))" for source in client.sources]
    sinks = ASCIIString["(\"$(sink.name)\", $(nchannels(sink)))" for sink in client.sinks]
    print_joined(io, sources, ", ")
    print(io, "], [")
    print_joined(io, sinks, ", ")
    print(io, "])")
end

function Base.close(client::JackClient)
    if client.ptr != C_NULL
        deactivate(client)
    end
    if client.portptrs != C_NULL
        free(client.portptrs)
        client.portptrs = C_NULL
    end
    for i in length(client.sources):-1:1
        close(client.sources[i], client.ptr)
        deleteat!(client.sources, i)
    end
    for i in length(client.sinks):-1:1
        close(client.sinks[i], client.ptr)
        deleteat!(client.sinks, i)
    end
    if client.ptr != C_NULL
        status = jack_client_close(client.ptr)
        client.ptr = C_NULL
        if status != Int(Success)
            error("Error closing client $(client.name): $(status_str(status))")
        end
    end
    
    nothing
end

# this should only get called during construction
function activate(client::JackClient)
    status = ccall((:jack_activate, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error activating client $(client.name): $(status_str(status))")
    end
    
    nothing
end

# this should only get called when closing the client
function deactivate(client::JackClient)
    status = ccall((:jack_deactivate, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error deactivating client $(client.name): $(status_str(status))")
    end
    
    nothing
end


# TODO: handle multiple writer situation
# handle writes from a buffer with matching channel count and sample rate. Up/Down
# mixing and resampling should be the responsibility of SampleTypes.jl
function Base.write{N, SR}(sink::JackSink{N, SR}, buf::SampleBuf{N, SR, JackSample})
    # a JackSink{N. SR} should always have N set of pointers, by construction
    @assert length(sink.ptrs) == N
    nbytes = Csize_t(nframes(buf) * sizeof(JackSample))
    bytesleft = ones(Csize_t, N) * nbytes
    chanptrs = Ptr{JackSample}[channelptr(buf, ch) for ch in 1:N]
    
    for (ch, pair) in enumerate(sink.ptrs)
        n = jack_ringbuffer_write(pair.ringbuf, chanptrs[ch], bytesleft[ch])
        bytesleft[ch] -= n
        chanptrs[ch] += n
    end
    while any(x -> x > 0, bytesleft)
        # wait to be notified that some space has freed up in the ringbuf
        wait(sink.ringcondition)
        for (ch, pair) in enumerate(sink.ptrs)
            n = jack_ringbuffer_write(pair.ringbuf, chanptrs[ch], bytesleft[ch])
            bytesleft[ch] -= n
            chanptrs[ch] += n
        end
    end
    
    # by now we know we've written the whole length of the buffer
    nframes(buf)
end

# TODO: handle multiple reader situation
function Base.read!{N, SR}(source::JackSource{N, SR}, buf::SampleBuf{N, SR, JackSample})
    nbytes = Csize_t(nframes(buf) * sizeof(JackSample))
    bytesleft = ones(Csize_t, N) * nbytes
    chanptrs = Ptr{JackSample}[channelptr(buf, ch) for ch in 1:N]
    # note, we could end up reading partial floats here, so things may be
    # wacky if this process gets interrupted
    for (ch, pair) in enumerate(source.ptrs)
        n = jack_ringbuffer_read(pair.ringbuf, chanptrs[ch], bytesleft[ch])
        bytesleft[ch] -= n
        chanptrs[ch] += n
    end
    while any(x -> x > 0, bytesleft)
        # wait to be notified that new samples are available in the ringbuf
        wait(source.ringcondition)
        for (ch, pair) in enumerate(source.ptrs)
            n = jack_ringbuffer_read(pair.ringbuf, chanptrs[ch], bytesleft[ch])
            bytesleft[ch] -= n
            chanptrs[ch] += n
        end
    end
    
    # by now we know we've read the whole length of the buffer
    nframes(buf)
end

# This gets called from a separate thread, so it is VERY IMPORTANT that it not
# allocate any memory or JIT compile when it's being run. Here be segfaults.
function process(nframes, portptrs)
    nbytes::Csize_t = nframes * sizeof(JackSample)
    
    ptridx = 1
    # handle sources
    while unsafe_load(portptrs, ptridx) != C_NULL
        source = unsafe_load(portptrs, ptridx)
        ringbuf = unsafe_load(portptrs, ptridx + 1)
        ptridx += 2
    
        if nbytes > jack_ringbuffer_write_space(ringbuf)
            # we wouldn't have enough space to write and would fill the buffer,
            # which can cause things to get mis-aligned. Let's make some room
            jack_ringbuffer_read_advance(ringbuf, nbytes)
        end

        buf = jack_port_get_buffer(source, nframes)
        jack_ringbuffer_write(ringbuf, buf, nbytes)
    end
    # skip over the null terminator
    ptridx += 1
    
    # handle sinks
    
    while unsafe_load(portptrs, ptridx) != C_NULL
        sink = unsafe_load(portptrs, ptridx)
        ringbuf = unsafe_load(portptrs, ptridx + 1)
        ptridx += 2
        
        buf = jack_port_get_buffer(sink, nframes)
        bytesread = jack_ringbuffer_read(ringbuf, buf, nbytes)
        if bytesread != nbytes
            memset(buf+bytesread, 0, nbytes - bytesread)
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

# this callback gets called from within the Julia event loop, but is triggered
# by every `process` call. It bumps any tasks waiting to read or write
function managebuffers(client)
    for source in client.sources
        notify(source.ringcondition)
    end
    for sink in client.sinks
        notify(sink.ringcondition)
    end
end

function shutdown(arg)
    nothing
end

# low-level libjack wrapper functions

jack_client_open(name, options, statusref) =
    ccall((:jack_client_open, :libjack), ClientPtr,
        (Cstring, Cint, Ref{Cint}),
        name, 0, statusref)
        
jack_client_close(client) =
    ccall((:jack_client_close, :libjack), Cint, (ClientPtr, ), client)
            
jack_get_client_name(client) =
    ccall((:jack_get_client_name, :libjack), Cstring, (ClientPtr, ), client)
    
jack_get_sample_rate(client) =
    ccall((:jack_get_sample_rate, :libjack), NFrames, (ClientPtr, ), client)
        
jack_set_process_callback(client, callback, userdata) =
    ccall((:jack_set_process_callback, :libjack), Cint,
        (ClientPtr, CFunPtr, Ptr{Void}),
        client, callback, userdata)
        
jack_on_shutdown(client, callback, userdata) =
    ccall((:jack_on_shutdown, :libjack), Cint,
        (ClientPtr, CFunPtr, Ptr{Void}),
        client, callback, userdata)

jack_port_register(client, portname, porttype, flags, bufsize) =
    ccall((:jack_port_register, :libjack), PortPtr,
        (ClientPtr, Cstring, Cstring, Culong, Culong),
        client, portname, porttype, flags, bufsize)

jack_port_unregister(client, port) =
    ccall((:jack_port_unregister, :libjack), Cint, (ClientPtr, PortPtr),
        client, port)
        
jack_port_get_buffer(port, nframes) =
    ccall((:jack_port_get_buffer, :libjack), Ptr{JackSample},
        (PortPtr, NFrames),
        port, nframes)
        
jack_ringbuffer_create(bytes) =
    ccall((:jack_ringbuffer_create, :libjack), Ptr{RingBuf}, (Csize_t, ), bytes)

jack_ringbuffer_free(buf) =
    ccall((:jack_ringbuffer_free, :libjack), Void, (Ptr{RingBuf}, ), buf)

jack_ringbuffer_read(ringbuf, dest, bytes) =
    ccall((:jack_ringbuffer_read, :libjack), Csize_t,
        (Ptr{RingBuf}, Ptr{Void}, Csize_t), ringbuf, dest, bytes)

jack_ringbuffer_read_advance(ringbuf, bytes) =
    ccall((:jack_ringbuffer_read_advance, :libjack), Void,
        (Ptr{RingBuf}, Csize_t), ringbuf, bytes)

jack_ringbuffer_read_space(ringbuf) =
    ccall((:jack_ringbuffer_read_space, :libjack), Csize_t,
        (Ptr{RingBuf}, ), ringbuf)

jack_ringbuffer_write(ringbuf, src, bytes) =
    ccall((:jack_ringbuffer_write, :libjack), Csize_t,
        (Ptr{RingBuf}, Ptr{Void}, Csize_t), ringbuf, src, bytes)

jack_ringbuffer_write_space(ringbuf) =
    ccall((:jack_ringbuffer_write_space, :libjack), Csize_t,
        (Ptr{RingBuf}, ), ringbuf)

memset(buf, val, count) = ccall(:memset, Ptr{Void},
    (Ptr{Void}, Cint, Csize_t),
    buf, 0, count)


end # module
