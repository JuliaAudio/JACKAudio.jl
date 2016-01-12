module JACKAudio

export JackClient, activate
export JackSource, JackSink

using Logging

Logging.configure(level=DEBUG)

include("jack_types.jl")

function __init__()
    ccall((:jack_set_info_function, :libjack), Void, (Ptr{Void},),
        info_handler_cb)
    ccall((:jack_set_error_function, :libjack), Void, (Ptr{Void},),
        error_handler_cb)
end

function process(nframes, arg)
    Cint(0)
end
const process_cb = cfunction(process, Cint, (NFrames, Ptr{Void}))

function shutdown(arg)
    nothing
end
const shutdown_cb = cfunction(shutdown, Void, (Ptr{Void}, ))

function error_handler(msg)
    err("libjack: $(bytestring(msg))")

    nothing
end
const error_handler_cb = cfunction(error_handler, Void, (Ptr{Cchar}, ))

function info_handler(msg)
    info("libjack: $(bytestring(msg))")

    nothing
end
const info_handler_cb = cfunction(info_handler, Void, (Ptr{Cchar}, ))

immutable JackClient
    name::ASCIIString
    ptr::ClientPtr

    function JackClient(name::ASCIIString)
        status = Ref{Cint}(Int(Failure))
        ptr = ccall((:jack_client_open, :libjack), ClientPtr, (Ptr{Cchar}, Cint, Ref{Cint}),
            name, 0, status)
        if ptr == C_NULL
            error("Failure opening JACK Client: ", status_str(status[]))
        end
        if status[] & ServerStarted
            info("Started JACK Server")
        end
        if status[] & NameNotUnique
            new_name = ccall((:jack_get_client_name, :libjack), Ptr{Cchar}, (ClientPtr, ), ptr);
            name = bytestring(new_name)
            info("Given name not unique, renamed to ", name)
        end
        debug("Opened JACK Client with status: ", status_str(status[]))
        
        client = new(name, ptr)
        Clients[ptr] = client
        
        # give the client ptr as user data to the process callback, so we'll know which
        # client is being processed
        ccall((:jack_set_process_callback, :libjack), Cint, (ClientPtr, CFunPtr, Ptr{Void}),
            ptr, process_cb, ptr)
        ccall((:jack_on_shutdown, :libjack), Cint, (ClientPtr, CFunPtr, Ptr{Void}),
            ptr, shutdown_cb, ptr)
            
        client
    end
end

function Base.close(client::JackClient)
    status = ccall((:jack_client_close, :libjack), Cint, (ClientPtr, ), client.ptr)
    delete!(Clients, client.ptr)
    if status != Int(Success)
        error("Error closing client $(client.name): $(status_str(status))")
    end
    
    nothing
end

function activate(client::JackClient)
    status = ccall((:jack_activate, :libjack), Cint, (ClientPtr, ), client.ptr)
    if status != Int(Success)
        error("Error activating client $(client.name): $(status_str(status))")
    end
end

const Clients = Dict{ClientPtr, JackClient}()

for (T, porttype) in [(:JackSource, :PortIsOutput), (:JackSink, :PortIsInput)]
    @eval immutable $T
        name::ASCIIString
        ptr::PortPtr
        
        function $T(client::JackClient, name::ASCIIString)
            # buffer size is ignored for a default port type
            ptr = jack_port_register(client.ptr, name, JACK_DEFAULT_AUDIO_TYPE, $porttype, 0)
            if ptr == C_NULL
                error("Failed to create port $(client.name):$name")
            end
            
            new(name, ptr)
        end
    end
end

# low-level libjack wrapper functions

jack_port_register(client, portname, porttype, flags, bufsize) =
    ccall((:jack_port_register, :libjack), PortPtr,
        (ClientPtr, Ptr{Cchar}, Ptr{Cchar}, Culong, Culong),
        client, portname, porttype, flags, bufsize)


end # module
