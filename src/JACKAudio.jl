__precompile__()

module JACKAudio

export JackClient, activate, deactivate
export JackSource, JackSink

# TODO: Logging is segfaulting when used inside the precompiled callback function
# using Logging

# Logging.configure(level=DEBUG)

include("jack_types.jl")

const RINGBUF_SAMPLES = 96000

function __init__()
    global const process_cb = cfunction(process, Cint, (NFrames, Ptr{JackClient}))
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

# JackSource and JackSink defs are almost identical, so DRY it out with some
# metaprogramming magic
for (T, porttype) in [(:JackSource, :PortIsInput), (:JackSink, :PortIsOutput)]
    @eval immutable $T
        name::ASCIIString
        ptr::PortPtr
        ringbuf::Ptr{RingBuffer}
        
        function $T(client, name::ASCIIString)
            client.active && error("Ports an only be added to an inactive client")
            # buffer size is ignored for a default port type
            ptr = jack_port_register(client.ptr, name, JACK_DEFAULT_AUDIO_TYPE, $porttype, 0)
            if ptr == C_NULL
                error("Failed to create port $(client.name):$name")
            end
            bufptr = jack_ringbuffer_create(RINGBUF_SAMPLES * sizeof(JackSample))
            
            port = new(name, ptr, bufptr)
            push!(client, port)
            
            port
        end
    end
end

type JackClient
    name::ASCIIString
    ptr::ClientPtr
    sources::Vector{JackSource}
    sinks::Vector{JackSink}
    active::Bool

    function JackClient(name::ASCIIString)
        status = Ref{Cint}(Int(Failure))
        ptr = ccall((:jack_client_open, :libjack), ClientPtr, (Cstring, Cint, Ref{Cint}),
            name, 0, status)
        if ptr == C_NULL
            error("Failure opening JACK Client: ", status_str(status[]))
        end
        if status[] & ServerStarted
            info("Started JACK Server")
        end
        if status[] & NameNotUnique
            new_name = ccall((:jack_get_client_name, :libjack), Cstring, (ClientPtr, ), ptr);
            name = bytestring(new_name)
            info("Given name not unique, renamed to ", name)
        end
        println("Opened JACK Client with status: ", status_str(status[]))
        
        client = new(name, ptr, JackSource[], JackSink[], false)
        
        # give the client ptr as user data to the process callback, so we'll know which
        # client is being processed
        println("setting process callback to $process_cb")
        ccall((:jack_set_process_callback, :libjack), Cint, (ClientPtr, CFunPtr, Ptr{JackClient}),
            ptr, process_cb, pointer_from_objref(client))
        ccall((:jack_on_shutdown, :libjack), Cint, (ClientPtr, CFunPtr, Ptr{JackClient}),
            ptr, shutdown_cb, pointer_from_objref(client))
            
        client
    end
end

JackClient(; kwargs...) = JackClient("Julia"; kwargs...)

function Base.close(client::JackClient)
    status = ccall((:jack_client_close, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error closing client $(client.name): $(status_str(status))")
    end
    
    nothing
end

function activate(client::JackClient)
    client.active = true
    status = ccall((:jack_activate, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error activating client $(client.name): $(status_str(status))")
    end
    
    nothing
end

function deactivate(client::JackClient)
    # if the client isn't active there's nothing to do
    client.active || return nothing
    status = ccall((:jack_deactivate, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error deactivating client $(client.name): $(status_str(status))")
    end
    client.active = false
    
    nothing
end

# these push! methods are mostly to make the metaprogramming that defines sinks
# and sources easier. They shouldn't be used by application code because the
# sources and # sinks are already added to the client on construction
function Base.push!(client::JackClient, source::JackSource)
    client.active && error("Ports an only be added to an inactive client")
    push!(client.sources, source)
end

function Base.push!(client::JackClient, sink::JackSink)
    client.active && error("Ports an only be added to an inactive client")
    push!(client.sinks, sink)
end

function Base.delete!(client::JackClient, source::JackSource)
    client.active && error("Ports an only be removed from an inactive client")
    deleteat!(client.sources, findfirst(client.sources, source))
    jack_port_unregister(client.ptr, source.ptr)
    jack_ringbuffer_free(source.ringbuf)
end

function Base.delete!(client::JackClient, sink::JackSink)
    client.active && error("Ports an only be removed from an inactive client")
    deleteat!(client.sinks, findfirst(client.sinks, sink))
    jack_port_unregister(client.ptr, sink.ptr)
    jack_ringbuffer_free(sink.ringbuf)
end

function Base.write(sink::JackSink, buf::Array{JackSample})
    nbytes = length(buf) * sizeof(JackSample)
    jack_ringbuffer_write(sink.ringbuf, buf, nbytes)
end

# This gets called from a separate thread, so it is VERY IMPORTANT that it not
# allocate any memory or JIT compile when it's being run.
# TODO: verify the types of things to make sure there aren't any unnecessary
# conversions or boxed values
function process(nframes, clientPtr)
    clientPtr == Ptr{JackClient}(0) && return Cint(0)
    nbytes = nframes * sizeof(JackSample)
    client = unsafe_pointer_to_objref(clientPtr)::JackClient
    for i in eachindex(client.sources)
        @inbounds source = client.sources[i]
        buf = jack_port_get_buffer(source.ptr, nframes)
        jack_ringbuffer_write(source.ringbuf, buf, nbytes)
    end
    for i in eachindex(client.sinks)
        @inbounds sink = client.sinks[i]
        buf = jack_port_get_buffer(sink.ptr, nframes)
        bytesread = jack_ringbuffer_read(sink.ringbuf, buf, nbytes)
        if bytesread != nbytes
            memset(buf, 0, nbytes - bytesread)
        end
    end
    
    Cint(0)
end

function shutdown(arg)
    nothing
end

# low-level libjack wrapper functions

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
    ccall((:jack_ringbuffer_create, :libjack), Ptr{RingBuffer}, (Csize_t, ), bytes)

jack_ringbuffer_free(buf) =
    ccall((:jack_ringbuffer_free, :libjack), Void, (Ptr{RingBuffer}, ), buf)

jack_ringbuffer_read(ringbuf, dest, bytes) =
    ccall((:jack_ringbuffer_read, :libjack), Csize_t,
        (Ptr{RingBuffer}, Ptr{Void}, Csize_t), ringbuf, dest, bytes)

jack_ringbuffer_write(ringbuf, src, bytes) =
    ccall((:jack_ringbuffer_write, :libjack), Csize_t,
        (Ptr{RingBuffer}, Ptr{Void}, Csize_t), ringbuf, src, bytes)

memset(buf, val, count) = ccall(:memset, Ptr{Void},
    (Ptr{Void}, Cint, Csize_t),
    buf, 0, count)
    
end # module
