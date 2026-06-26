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
# Request types are `eval`/`ping`, response types `ok`/`err`/`pong`. The type code
# is an open enum: new response codes (a serialized value, a MIME bundle) extend
# the protocol without a format break. Every read validates magic, version, type,
# and length before trusting the body.
#

const READ_TIMEOUT_SECONDS = 30.0
const MAX_REQUEST_BYTES = 16 * 1024 * 1024  # 16MB

const PROTOCOL_MAGIC = Vector{UInt8}("REPL")
const PROTOCOL_VERSION = 0x01
const FRAME_HEADER_BYTES = length(PROTOCOL_MAGIC) + 6  # magic + version + type + UInt32 length

const REQUEST_EVAL = 0x01
const REQUEST_PING = 0x02
const RESPONSE_OK = 0x01
const RESPONSE_ERR = 0x02
const RESPONSE_PONG = 0x03

const REQUEST_TYPES = (REQUEST_EVAL, REQUEST_PING)
const RESPONSE_TYPES = (RESPONSE_OK, RESPONSE_ERR, RESPONSE_PONG)

# Run a blocking read on `sock`, closing the socket if it outlives the timeout so
# the read unblocks with an IOError instead of hanging. The caller closes `sock`
# again in its own `finally`; the second close is a no-op.
function _read_with_timeout(thunk, sock; timeout_seconds = READ_TIMEOUT_SECONDS)
    timed_out = Ref(false)
    timer = Timer(timeout_seconds) do _
        timed_out[] = true
        close(sock)
    end
    return try
        thunk()
    catch
        timed_out[] && throw(
            ErrorException(
                "Read timeout: no data received within $(timeout_seconds) seconds",
            ),
        )
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

# Validate a frame header and return its `(type, body_length)`. Throws on any
# compliance violation: bad magic, wrong version, unknown type, oversized body.
function _parse_header(header::Vector{UInt8}, valid_types::Tuple{Vararg{UInt8}}, max_bytes::Int)
    buffer = IOBuffer(header)
    magic = read(buffer, length(PROTOCOL_MAGIC))
    magic == PROTOCOL_MAGIC ||
        error("Unknown protocol: expected magic \"REPL\", got $(repr(String(magic)))")

    version = read(buffer, UInt8)
    version == PROTOCOL_VERSION ||
        error("Protocol version mismatch: expected $(PROTOCOL_VERSION), got $version")

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
    header = _read_with_timeout(sock; timeout_seconds) do
        read(sock, FRAME_HEADER_BYTES)
    end::Vector{UInt8}
    isempty(header) && return nothing
    length(header) == FRAME_HEADER_BYTES ||
        error("Incomplete frame header: expected $FRAME_HEADER_BYTES bytes, got $(length(header))")

    type, count = _parse_header(header, valid_types, max_bytes)
    count == 0 && return (; type, body = "")

    body = _read_with_timeout(sock; timeout_seconds) do
        read(sock, count)
    end::Vector{UInt8}
    length(body) == count ||
        error("Incomplete frame: expected $count body bytes, got $(length(body))")
    return (; type, body = String(body))
end

# Drain the client's framed request before replying so it completes its write and
# reads the rejection, rather than hitting EPIPE on flush against a socket we
# already closed.
function _reject_at_capacity(sock::IO, id, read_timeout_seconds)
    return try
        _read_frame(sock, REQUEST_TYPES; timeout_seconds = read_timeout_seconds)
        _write_frame(sock, RESPONSE_ERR, "Server at capacity, please retry")
    catch error
        @debug "Failed to send capacity error to client" id error
    finally
        close(sock)
    end
end

function _handle_client(sock::IO, id::Integer, mod::Union{Module, Nothing}, read_timeout_seconds, verbose)
    return try
        frame = _read_frame(sock, REQUEST_TYPES; timeout_seconds = read_timeout_seconds)

        # Bare disconnect: nothing to reply to.
        isnothing(frame) && return

        if frame.type == REQUEST_PING
            _write_frame(sock, RESPONSE_PONG, "")
            return
        end

        verbose && @info "Received code" id code = Text(frame.body)

        result = _evaluate(frame.body, id, mod)
        _write_frame(sock, result.errored ? RESPONSE_ERR : RESPONSE_OK, result.output)

        verbose && @info "Sent result" id result = Text(result.output)
    catch error
        @error "Error handling client" id error
        try
            # Inform the client about a protocol or framing error.
            _write_frame(sock, RESPONSE_ERR, sprint(showerror, error))
        catch error
            # Client disconnected before we could send the error.
            @error "Failed to send error frame to client" id error
        end
    finally
        # Always close the socket to free resources and signal EOF to the client.
        close(sock)
        verbose && @info "Client disconnected" id
    end
end
