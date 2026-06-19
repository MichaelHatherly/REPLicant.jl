#
# Wire protocol.
#

const READ_TIMEOUT_SECONDS = 30.0
const MAX_REQUEST_BYTES = 16 * 1024 * 1024  # 16MB

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

# Read one length-prefixed request: a byte-count line, then exactly that many
# bytes. An empty count line (disconnect) or a zero count is a no-op.
function _read_request(
        sock;
        timeout_seconds = READ_TIMEOUT_SECONDS,
        max_bytes = MAX_REQUEST_BYTES,
    )
    count_line = _read_with_timeout(sock; timeout_seconds) do
        readline(sock)
    end
    isempty(count_line) && return ""

    count = tryparse(Int, strip(count_line))
    isnothing(count) &&
        error("Malformed request: expected a byte count, got $(repr(count_line))")
    count < 0 && error("Malformed request: negative byte count $count")
    count > max_bytes &&
        error("Request too large: $count bytes exceeds maximum of $max_bytes")
    count == 0 && return ""

    bytes = _read_with_timeout(sock; timeout_seconds) do
        read(sock, count)
    end
    length(bytes) == count ||
        error("Incomplete request: expected $count bytes, got $(length(bytes))")
    return String(bytes)
end

# Drain the client's framed request before replying so a length-prefixed client
# completes its write and reads the rejection, rather than hitting EPIPE on flush
# against a socket we already closed.
function _reject_at_capacity(sock, id, read_timeout_seconds)
    return try
        _read_request(sock; timeout_seconds = read_timeout_seconds)
        write(sock, "ERROR: Server at capacity, please retry")
        flush(sock)
    catch error
        @debug "Failed to send capacity error to client" id error
    finally
        close(sock)
    end
end

function _handle_client(sock, id, mod, read_timeout_seconds, verbose)
    return try
        code = _read_request(sock; timeout_seconds = read_timeout_seconds)

        # Zero-length request (health probe) or a bare disconnect: reply empty.
        isempty(code) && return

        verbose && @info "Received code" id code = Text(code)

        result = _eval_code(code, id, mod)

        # The response is the raw result; the client reads until we close.
        write(sock, result)
        flush(sock)

        verbose && @info "Sent result" id result = Text(result)
    catch error
        @error "Error handling client" id error
        try
            # Attempt to inform the client about the error
            write(sock, "ERROR: $(error)")
            flush(sock)
        catch error
            # Client disconnected before we could send the error.
            @error "Failed to send error message to client" id error
        end
    finally
        # Always close the socket to free resources and signal EOF to the client.
        close(sock)
        verbose && @info "Client disconnected" id
    end
end
