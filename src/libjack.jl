const ClientPtr = Ptr{Void}
const PortPtr = Ptr{Void}
const CFunPtr = Ptr{Void}
const NFrames = UInt32
const JACKSample = Cfloat

const JACK_DEFAULT_AUDIO_TYPE = "32 bit float mono audio"

# this mirrors the struct defined in ringbuffer.h 
type RingBuf
    buf::Ptr{Cchar}
    write_ptr::Csize_t
    read_ptr::Csize_t
    size::Csize_t
    size_mask::Csize_t
    mlocked::Cint
end
# add typealias for consistency with other *Ptr types
const RingBufPtr = Ptr{RingBuf}

@enum(Option,
    # Null value to use when no option bits are needed.
    NullOption = 0x00,
    # Do not automatically start the JACK server when it is not
    # already running.  This option is always selected if
    # `JACK_NO_START_SERVER` is defined in the calling process
    # environment.
    NoStartServer = 0x01,
    # Use the exact client name requested. Otherwise, JACK
    # automatically generates a unique one, if needed.
    UseExactName = 0x02,
    # Open with optional server_name parameter.
    ServerName = 0x04,
    # Load internal client from optional
    # load_name.  Otherwise use the client_name.
    LoadName = 0x08,
    # Pass optional load_init string to the
    # jack_initialize() entry point of an internal client.
    LoadInit = 0x10,
    # pass a SessionID Token this allows the sessionmanager to identify the client again.
    SessionID = 0x20)

# useful for OR'ing options together
@compat Base.:|(l::Option, r::Option) = UInt(l) | UInt(r)

@enum(PortFlag,
  PortIsInput = 0x01,
  PortIsOutput = 0x02, 
  PortIsPhysical = 0x04, 
  PortCanMonitor = 0x08, 
  PortIsTerminal = 0x10)

@compat Base.:|(l::PortFlag, r::PortFlag) = UInt(l) | UInt(r)

# some functions also return a -1 on failure
@enum(Status,
    Success = 0x00,
    # Overall operation failed.
    Failure = 0x01,
    # The operation contained an invalid or unsupported option.
    InvalidOption = 0x02,
    # The desired client name was not unique.  With the
    # JACKUseExactName option this situation is fatal.  Otherwise,
    # the name was modified by appending a dash and a two-digit
    # number in the range "-01" to "-99".  The
    # jack_get_client_name() function will return the exact string
    # that was used.  If the specified client_name plus these
    # extra characters would be too long, the open fails instead.
    NameNotUnique = 0x04,
    # The JACK server was started as a result of this operation.
    # Otherwise, it was running already.  In either case the caller
    # is now connected to jackd, so there is no race condition.
    # When the server shuts down, the client will find out.
    ServerStarted = 0x08,
    # Unable to connect to the JACK server.
    ServerFailed = 0x10,
    # Communication error with the JACK server.
    ServerError = 0x20,
    # Requested client does not exist.
    NoSuchClient = 0x40,
    # Unable to load internal client
    LoadFailure = 0x80,
    # Unable to initialize client
    InitFailure = 0x100,
    # Unable to access shared memory
    ShmFailure = 0x200,
    # Client's protocol version does not match
    VersionError = 0x400,
    # Backend error
    BackendError = 0x800,
    # Client zombified failure
    ClientZombie = 0x1000)

status_str(status::Status) = string(status)

# use & syntax for checking a flag, but return a boolean
@compat Base.:&{T <: Integer}(val::T, status::Status) = val & T(status) != 0

function status_str(status::Integer)
    if status == -1
        "GeneralError"
    elseif status == Int(Success)
        string(Status(status))
    else
        selected = filter(flag -> status & UInt(flag) != 0, instances(Status))
        join(selected, ", ")
    end
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

jack_get_ports(client, portname, typename, flags) =
    ccall((:jack_get_ports, :libjack), Ptr{Cstring},
        (ClientPtr, Cstring, Cstring, Culong),
        client, portname, typename, flags)

jack_connect(client, src, dest) =
    ccall((:jack_connect, :libjack), Cint, (ClientPtr, Cstring, Cstring),
    client, src, dest)

jack_free(ptr) = ccall((:jack_free, :libjack), Void, (Ptr{Void}, ), ptr)

jack_port_register(client, portname, porttype, flags, bufsize) =
    ccall((:jack_port_register, :libjack), PortPtr,
        (ClientPtr, Cstring, Cstring, Culong, Culong),
        client, portname, porttype, flags, bufsize)

jack_port_unregister(client, port) =
    ccall((:jack_port_unregister, :libjack), Cint, (ClientPtr, PortPtr),
        client, port)

jack_port_get_buffer(port, nframes) =
    ccall((:jack_port_get_buffer, :libjack), Ptr{JACKSample},
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
