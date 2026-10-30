#
# Wire protocol.
#
# Frames run in both directions: a fixed header followed by a body.
#
#   "REPL"   magic        4 bytes
#   version  UInt8        1 byte
#   type     UInt8        1 byte   message type code
#   length   UInt32 (BE)  4 bytes  body byte count
#   body     length bytes          UTF-8
#
# Request types are `eval`/`ping`/`interrupt`/`reset`/`log`/`restart`, response types
# `ok`/`err`/`pong`. Every request body opens with the server's token (see
# `_read_request`). After it, an `eval` body is structured (see `_encode_eval_body`);
# the others are a name, a count, or empty. The type code is an open enum: new codes (a
# `log` query, a serialized value, a MIME bundle) extend the protocol without a
# format break. Every read validates magic, version, type, and length before
# trusting the body.
#

const READ_TIMEOUT_SECONDS = 30.0
# The longest wait a `Timer` accepts: libuv counts it in UInt64 milliseconds.
const MAX_TIMEOUT_SECONDS = typemax(UInt64) / 1000
# Liveness probes are answered off the worker queue, so a live server always
# replies in milliseconds. A short timeout keeps `ls` and resolution snappy and
# lets a wedged or version-skewed peer read as dead quickly.
const PING_TIMEOUT_SECONDS = 2.0
const MAX_REQUEST_BYTES = 16 * 1024 * 1024  # 16MB
# An eval's output is bounded only by what it prints. The client trusts its server,
# so it accepts any body the header can express.
const MAX_RESPONSE_BYTES = Int(typemax(UInt32))

# Appended to magic/version mismatch errors. A peer that fails the header checks
# is usually a client or server on a different REPLicant version, which the
# `julia +rpc` channel does not catch on its own.
const VERSION_SKEW_HELP = "The client and server may be running different REPLicant versions. Reinstall the rpc channel: julia -e 'using REPLicant; REPLicant.install_channel(force = true)'"

const PROTOCOL_MAGIC = Vector{UInt8}("REPL")
const PROTOCOL_VERSION = 0x03
const FRAME_HEADER_BYTES = length(PROTOCOL_MAGIC) + 6  # magic + version + type + UInt32 length

const REQUEST_EVAL = 0x01
const REQUEST_PING = 0x02
const REQUEST_INTERRUPT = 0x03
const REQUEST_RESET = 0x04
const REQUEST_LOG = 0x05
const REQUEST_RESTART = 0x06
const RESPONSE_OK = 0x01
const RESPONSE_ERR = 0x02
const RESPONSE_PONG = 0x03

const REQUEST_TYPES =
    (REQUEST_EVAL, REQUEST_PING, REQUEST_INTERRUPT, REQUEST_RESET, REQUEST_LOG, REQUEST_RESTART)
const RESPONSE_TYPES = (RESPONSE_OK, RESPONSE_ERR, RESPONSE_PONG)

# An eval frame body carries the caller's working directory and target module name
# alongside the code, so the server runs the eval in the caller's directory and in
# the named session. Each field is its byte length as ASCII digits, a newline, then
# that many bytes; the code is whatever remains. Byte lengths keep multibyte paths
# exact and let the code carry arbitrary newlines. An empty `cwd` skips the
# server-side `cd`; an empty `mod` evaluates into the default module.
function _encode_eval_body(; cwd::AbstractString, mod::AbstractString, code::AbstractString)
    return string(ncodeunits(cwd), '\n', cwd, ncodeunits(mod), '\n', mod, code)
end

function _decode_eval_body(body::AbstractString)
    bytes = codeunits(body)
    cwd, pos = _take_field(bytes, firstindex(bytes))
    mod, pos = _take_field(bytes, pos)
    return (; cwd, mod, code = String(bytes[pos:end]))
end

# Read one length-prefixed field starting at `pos`: ASCII digits, a newline, then
# that many bytes. Returns the field and the index just past it.
function _take_field(bytes, pos::Integer)
    newline = findnext(==(UInt8('\n')), bytes, pos)
    isnothing(newline) && error("malformed eval body: missing field length")
    count = parse(Int, String(bytes[pos:(newline - 1)]))
    start = newline + 1
    stop = start + count - 1
    (count < 0 || stop > lastindex(bytes)) &&
        error("malformed eval body: field length out of range")
    return String(bytes[start:stop]), stop + 1
end

# A read that outlived its bound. Carries the bound so callers can phrase their own
# message; `showerror` keeps the wire-facing text servers reply to clients with.
struct ReadTimeout <: Exception
    timeout_seconds::Float64
end
Base.showerror(io::IO, err::ReadTimeout) =
    print(io, "Read timeout: no data received within $(err.timeout_seconds) seconds")

# A peer whose first bytes are not the REPLicant magic: another tool probing the
# port (an HTTP health check, say), or a client from a pre-framing release.
struct UnknownProtocol <: Exception
    magic::Vector{UInt8}
end
Base.showerror(io::IO, err::UnknownProtocol) = print(
    io,
    "Unknown protocol: expected magic \"REPL\", got $(repr(String(copy(err.magic)))). $VERSION_SKEW_HELP",
)

# Run a blocking read on `sock`, closing the socket if it outlives the timeout so
# the read unblocks with an IOError instead of hanging. The caller closes `sock`
# again in its own `finally`; the second close is a no-op. A `nothing` timeout
# blocks with no bound, for callers that must wait as long as the work takes.
function _read_with_timeout(thunk, sock; timeout_seconds = READ_TIMEOUT_SECONDS)
    isnothing(timeout_seconds) && return thunk()
    timed_out = Ref(false)
    timer = Timer(timeout_seconds) do _
        timed_out[] = true
        close(sock)
    end
    return try
        # Closing the socket may unblock the read by returning short/empty rather
        # than throwing, so the timeout is detected from the flag, not the throw.
        result = thunk()
        timed_out[] && throw(ReadTimeout(timeout_seconds))
        result
    catch
        timed_out[] && throw(ReadTimeout(timeout_seconds))
        rethrow()
    finally
        close(timer)
    end
end

# Write one frame: the fixed header, then the body bytes.
function _write_frame(io::IO, type::UInt8, body::String)
    write(io, PROTOCOL_MAGIC)
    write(io, PROTOCOL_VERSION)
    write(io, type)
    write(io, hton(UInt32(ncodeunits(body))))
    write(io, body)
    flush(io)
    return nothing
end

# Any local process can reach a loopback port, so a request proves it may run code
# by carrying the token from the server's registry entry, which only the owner can
# read. 32 random bytes, hex-encoded.
const TOKEN_LENGTH = 64
_new_token() = bytes2hex(rand(Random.RandomDevice(), UInt8, TOKEN_LENGTH ÷ 2))

struct Unauthorized <: Exception end
Base.showerror(io::IO, ::Unauthorized) = print(
    io,
    "Unauthorized: the request did not carry this server's token. A client reads it from the server's registry entry.",
)

# A request refused for what it asks, such as a reserved session name. The caller
# made the mistake and hears about it; the server has nothing to log.
struct RequestError <: Exception
    msg::String
end
Base.showerror(io::IO, error::RequestError) = print(io, error.msg)

_write_request(io::IO, token::String, type::UInt8, body::String) =
    _write_frame(io, type, string(token, body))

# Read a request frame and check its token, returning the frame with the token
# stripped from its body. The comparison runs in constant time.
#
# The token is read and checked before the rest of the body, so a peer without it
# cannot make the server buffer the body its header announces. The rest is still
# drained before the rejection, so the client finishes its write and reads it.
function _read_request(sock::IO, token::String, timeout_seconds::Float64)
    header = _read_header(sock, REQUEST_TYPES; timeout_seconds, max_bytes = MAX_REQUEST_BYTES)
    isnothing(header) && return nothing
    type, count = header
    if count < TOKEN_LENGTH
        _discard_body(sock, count; timeout_seconds)
        throw(Unauthorized())
    end
    presented = _read_body(sock, TOKEN_LENGTH; timeout_seconds)
    mismatch = 0x00
    for (actual, expected) in zip(presented, codeunits(token))
        mismatch |= actual ⊻ expected
    end
    if mismatch != 0x00
        _discard_body(sock, count - TOKEN_LENGTH; timeout_seconds)
        throw(Unauthorized())
    end
    return (; type, body = String(_read_body(sock, count - TOKEN_LENGTH; timeout_seconds)))
end

# Read and drop `count` body bytes a chunk at a time, holding no more than one chunk.
function _discard_body(sock::IO, count::Int; timeout_seconds)
    chunk = Vector{UInt8}(undef, min(count, 64 * 1024))
    remaining = count
    while remaining > 0
        n = min(remaining, length(chunk))
        _read_with_timeout(sock; timeout_seconds) do
            readbytes!(sock, chunk, n)
        end == n || error("Incomplete frame: expected $count body bytes")
        remaining -= n
    end
    return nothing
end

# Connect to the server on `port` and send one request carrying its registered
# token. Returns the socket for the caller to read the reply from and close.
function _open_request(port::Integer, type::UInt8, body::String)
    sock = Sockets.connect(Sockets.localhost, port)
    try
        _write_request(sock, _entry_token(port), type, body)
    catch
        close(sock)
        rethrow()
    end
    return sock
end

# Validate a frame header and return its `(type, body_length)`. Throws on any
# compliance violation: bad magic, wrong version, unknown type, oversized body.
function _parse_header(header::Vector{UInt8}, valid_types::Tuple{Vararg{UInt8}}, max_bytes::Int)
    buffer = IOBuffer(header)
    magic = read(buffer, length(PROTOCOL_MAGIC))
    magic == PROTOCOL_MAGIC || throw(UnknownProtocol(magic))

    version = read(buffer, UInt8)
    version == PROTOCOL_VERSION ||
        error("Protocol version mismatch: expected $(PROTOCOL_VERSION), got $version. $VERSION_SKEW_HELP")

    type = read(buffer, UInt8)
    any(==(type), valid_types) || error("Unknown message type: $type")

    count = Int(ntoh(read(buffer, UInt32)))
    count > max_bytes &&
        error("Frame too large: $count bytes exceeds maximum of $max_bytes")

    return type, count
end

# Read one frame, validating it against `valid_types`. Returns `(; type, body)`,
# or `nothing` when the peer closed without sending (a bare disconnect).
function _read_frame(
        sock::IO, valid_types::Tuple{Vararg{UInt8}};
        timeout_seconds = READ_TIMEOUT_SECONDS,
        max_bytes::Int = MAX_REQUEST_BYTES,
    )
    header = _read_header(sock, valid_types; timeout_seconds, max_bytes)
    isnothing(header) && return nothing
    type, count = header
    return (; type, body = String(_read_body(sock, count; timeout_seconds)))
end

# Read and validate a frame header, returning `(type, body_length)`, or `nothing`
# when the peer closed without sending.
function _read_header(sock::IO, valid_types::Tuple{Vararg{UInt8}}; timeout_seconds, max_bytes::Int)
    header = _read_with_timeout(sock; timeout_seconds) do
        read(sock, FRAME_HEADER_BYTES)
    end::Vector{UInt8}
    isempty(header) && return nothing
    length(header) == FRAME_HEADER_BYTES ||
        error("Incomplete frame header: expected $FRAME_HEADER_BYTES bytes, got $(length(header))")
    return _parse_header(header, valid_types, max_bytes)
end

# Read exactly `count` body bytes.
function _read_body(sock::IO, count::Int; timeout_seconds)
    count == 0 && return UInt8[]
    body = _read_with_timeout(sock; timeout_seconds) do
        read(sock, count)
    end::Vector{UInt8}
    length(body) == count ||
        error("Incomplete frame: expected $count body bytes, got $(length(body))")
    return body
end

# Drain the client's framed request before replying so it completes its write and
# reads the rejection, rather than hitting EPIPE on flush against a socket we
# already closed. A peer without the token is dropped once its token fails.
function _reject_at_capacity(sock::IO, id, token::String, read_timeout_seconds)
    return try
        _read_request(sock, token, read_timeout_seconds)
        _write_frame(sock, RESPONSE_ERR, "Server at capacity, please retry")
    catch error
        @debug "Failed to send capacity error to client" id error
    finally
        close(sock)
    end
end

# Log a handler failure and try to tell the client, tolerating a socket the peer
# has already closed. A foreign peer is routine traffic and logs at debug only.
function _reply_error(sock::IO, id::Integer, error)
    if error isa UnknownProtocol
        @debug "Rejected a peer speaking another protocol" id error
    elseif error isa Unauthorized
        @warn "Rejected a request without this server's token" id
    elseif error isa RequestError
        @debug "Rejected a request" id error
    elseif error isa ReadTimeout || error isa Base.IOError
        # Routine for a stalled peer or one that hung up, such as a client whose
        # `--timeout` expired. The socket is closed, so there is no one to reply to.
        return nothing
    else
        @error "Error handling client" id error
    end
    try
        _write_frame(sock, RESPONSE_ERR, sprint(showerror, error))
    catch error
        # Client disconnected before we could send the error.
        @error "Failed to send error frame to client" id error
    end
    return nothing
end

function _handle_eval(
        sock::IO, id::Integer, code::AbstractString, mod::Module,
        verbose, dir::AbstractString,
    )
    return try
        verbose && @info "Received code" id code = Text(code)

        # Revise inside the `try`, so a failed revision reaches the client as an error.
        result = _revise(_evaluate_request, code, id, mod, dir)::@NamedTuple{output::String, errored::Bool}
        _write_frame(sock, result.errored ? RESPONSE_ERR : RESPONSE_OK, result.output)

        verbose && @info "Sent result" id result = Text(result.output)
    catch error
        _reply_error(sock, id, error)
    finally
        # Always close the socket to free resources and signal EOF to the client.
        close(sock)
        verbose && @info "Client disconnected" id
    end
end
