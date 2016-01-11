module JACK

include("jack_types.jl")

function __init__()
    # set the info callback
    info("setting up callbacks")
    ccall((:jack_set_info_function, :libjack), Void, (Ptr{Void},),
        cfunction(info_handler, Void, (Ptr{Cchar},)))
    ccall((:jack_set_error_function, :libjack), Void, (Ptr{Void},),
        cfunction(error_handler, Void, (Ptr{Cchar},)))
end

function error_handler(msg)
    print_with_color(:red, string("ERROR: ", bytestring(msg)))
    println()

    nothing
end

function info_handler(msg)
    info(bytestring(msg))

    nothing
end

function JackClient(name::ASCIIString)
    status = Ref{Cint}(42)
    info("status is $status")
    ccall((:jack_client_open, :libjack), JackClient, (Ptr{Cchar}, Cint, Ref{Cint}),
        name, 0, status)
    info("Got status $status")
end


end # module
