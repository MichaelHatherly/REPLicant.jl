# Frame encoding/decoding over an in-memory buffer: fast, socket-free coverage of
# the wire format and its compliance checks.
@testitem "frame_roundtrip" tags = [:protocol, :frame] begin
    import REPLicant

    buf = IOBuffer()
    REPLicant._write_frame(buf, REPLicant.REQUEST_EVAL, "2 + 2")
    seekstart(buf)
    frame = REPLicant._read_frame(buf, REPLicant.REQUEST_TYPES)
    @test frame.type == REPLicant.REQUEST_EVAL
    @test frame.body == "2 + 2"

    # Zero-length body (ping/pong shape).
    buf = IOBuffer()
    REPLicant._write_frame(buf, REPLicant.REQUEST_PING, "")
    seekstart(buf)
    frame = REPLicant._read_frame(buf, REPLicant.REQUEST_TYPES)
    @test frame.type == REPLicant.REQUEST_PING
    @test frame.body == ""

    # Unicode body byte count is exact.
    buf = IOBuffer()
    REPLicant._write_frame(buf, REPLicant.RESPONSE_OK, "\"π🚀\"")
    seekstart(buf)
    frame = REPLicant._read_frame(buf, REPLicant.RESPONSE_TYPES)
    @test frame.body == "\"π🚀\""
end

@testitem "eval_body_roundtrip" tags = [:protocol, :frame] begin
    import REPLicant

    # Full round trip with a multibyte path, a module name, and code carrying
    # newlines: byte-length framing must reproduce each field exactly.
    body = REPLicant._encode_eval_body(; cwd = "/tmp/π", mod = "Session", code = "f(x)\n  x + 1\nend")
    decoded = REPLicant._decode_eval_body(body)
    @test decoded.cwd == "/tmp/π"
    @test decoded.mod == "Session"
    @test decoded.code == "f(x)\n  x + 1\nend"

    # Empty fields are the common case: no cwd, no module, just code.
    decoded = REPLicant._decode_eval_body(REPLicant._encode_eval_body(; cwd = "", mod = "", code = "1 + 1"))
    @test decoded.cwd == ""
    @test decoded.mod == ""
    @test decoded.code == "1 + 1"

    # Code containing the field delimiter byte stays intact past the two headers.
    decoded = REPLicant._decode_eval_body(REPLicant._encode_eval_body(; cwd = "", mod = "", code = "a\n2\nb"))
    @test decoded.code == "a\n2\nb"
end

@testitem "protocol_version_is_two" tags = [:protocol, :frame] begin
    import REPLicant
    @test REPLicant.PROTOCOL_VERSION == 0x02
end

@testitem "frame_bare_disconnect_is_nothing" tags = [:protocol, :frame] begin
    import REPLicant
    # An empty stream (peer closed without sending) reads as `nothing`, not an error.
    @test isnothing(REPLicant._read_frame(IOBuffer(), REPLicant.REQUEST_TYPES))
end

@testitem "frame_unknown_magic_rejected" tags = [:protocol, :frame] begin
    import REPLicant

    buf = IOBuffer()
    write(buf, b"NOPE")
    write(buf, REPLicant.PROTOCOL_VERSION)
    write(buf, REPLicant.REQUEST_EVAL)
    write(buf, hton(UInt32(1)))
    write(buf, "x")
    seekstart(buf)
    err = try
        REPLicant._read_frame(buf, REPLicant.REQUEST_TYPES)
        nothing
    catch e
        e
    end
    @test err isa Exception
    message = sprint(showerror, err)
    @test contains(message, "protocol")
    # The most common cause is a peer on a different REPLicant version, so the
    # error points at reinstalling the channel.
    @test contains(message, "install_channel")
end

@testitem "frame_version_mismatch_rejected" tags = [:protocol, :frame] begin
    import REPLicant

    buf = IOBuffer()
    write(buf, REPLicant.PROTOCOL_MAGIC)
    write(buf, REPLicant.PROTOCOL_VERSION + 0x01)
    write(buf, REPLicant.REQUEST_EVAL)
    write(buf, hton(UInt32(1)))
    write(buf, "x")
    seekstart(buf)
    err = try
        REPLicant._read_frame(buf, REPLicant.REQUEST_TYPES)
        nothing
    catch e
        e
    end
    @test err isa Exception
    message = sprint(showerror, err)
    @test contains(message, "version")
    @test contains(message, "install_channel")
end

@testitem "frame_unknown_type_rejected" tags = [:protocol, :frame] begin
    import REPLicant

    buf = IOBuffer()
    write(buf, REPLicant.PROTOCOL_MAGIC)
    write(buf, REPLicant.PROTOCOL_VERSION)
    write(buf, 0xFF)
    write(buf, hton(UInt32(0)))
    seekstart(buf)
    err = try
        REPLicant._read_frame(buf, REPLicant.REQUEST_TYPES)
        nothing
    catch e
        e
    end
    @test err isa Exception
    @test contains(sprint(showerror, err), "type")
end

@testitem "frame_oversized_length_rejected" tags = [:protocol, :frame] begin
    import REPLicant

    buf = IOBuffer()
    write(buf, REPLicant.PROTOCOL_MAGIC)
    write(buf, REPLicant.PROTOCOL_VERSION)
    write(buf, REPLicant.REQUEST_EVAL)
    write(buf, hton(UInt32(REPLicant.MAX_REQUEST_BYTES + 1)))
    seekstart(buf)
    err = try
        REPLicant._read_frame(buf, REPLicant.REQUEST_TYPES)
        nothing
    catch e
        e
    end
    @test err isa Exception
    @test contains(sprint(showerror, err), "too large")
end

@testitem "frame_incomplete_body_rejected" tags = [:protocol, :frame] begin
    import REPLicant
    # Header promises 10 body bytes, only 3 present before EOF.
    buf = IOBuffer()
    write(buf, REPLicant.PROTOCOL_MAGIC)
    write(buf, REPLicant.PROTOCOL_VERSION)
    write(buf, REPLicant.REQUEST_EVAL)
    write(buf, hton(UInt32(10)))
    write(buf, "abc")
    seekstart(buf)
    @test_throws Exception REPLicant._read_frame(buf, REPLicant.REQUEST_TYPES)
end

@testitem "basic_request" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "2 + 2") == "4"
    end
end

@testitem "multiline_request" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        code = "function f(x)\n    x + 1\nend\nf(41)"
        @test Utilities.request(port, code) == "42"
    end
end

@testitem "whitespace_handling" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "   3 + 3   ") == "6"
    end
end

@testitem "unicode_roundtrip" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "\"π\"") == "\"π\""
        @test Utilities.request(port, "\"🚀\"") == "\"🚀\""
    end
end

@testitem "large_output_handling" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        response = Utilities.request(port, "collect(1:1000)")
        @test contains(response, "1000-element Vector{Int64}")
    end
end

@testitem "error_response_format" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        frame = Utilities.requestframe(port, REPLicant.REQUEST_EVAL, "undefined_variable")
        @test frame.type == REPLicant.RESPONSE_ERR
        @test startswith(frame.body, "ERROR:")
        @test contains(frame.body, "UndefVarError")
    end
end

@testitem "ok_response_type" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        frame = Utilities.requestframe(port, REPLicant.REQUEST_EVAL, "2 + 2")
        @test frame.type == REPLicant.RESPONSE_OK
        @test frame.body == "4"
    end
end

@testitem "ping_pong" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        # The liveness probe is an explicit ping frame answered with pong.
        frame = Utilities.requestframe(port, REPLicant.REQUEST_PING, "")
        @test frame.type == REPLicant.RESPONSE_PONG
        @test frame.body == ""
    end
end

@testitem "eval_runs_while_busy" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        # Code is evaluated while the busy signal is set, so a remote eval can
        # observe `_is_busy()` as true. Outside the eval the server is idle.
        Core.eval(mod, :(import REPLicant))
        @test Utilities.request(port, "REPLicant._is_busy()") == "true"
        @test !REPLicant._is_busy()
    end
end

@testitem "ping_leaves_idle" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        # A liveness ping never enters the eval path, so it never marks busy.
        frame = Utilities.requestframe(port, REPLicant.REQUEST_PING, "")
        @test frame.type == REPLicant.RESPONSE_PONG
        @test !REPLicant._is_busy()
    end
end

@testitem "ping_answered_during_eval" tags = [:protocol] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # Occupy the worker with a long evaluation.
        busy = Utilities.sendframe(Sockets.connect(Sockets.localhost, port), "sleep(2); 1")
        sleep(0.2)  # let the eval reach the worker
        # The ping must be answered off the worker queue, not behind the 2s eval.
        elapsed = @elapsed answered = REPLicant._ping(port)
        @test answered
        @test elapsed < 1.0
        @test strip(Utilities.readresp(busy)) == "1"
        close(busy)
    end
end

@testitem "ping_times_out_on_silent_peer" tags = [:protocol, :timeout] begin
    import REPLicant
    import Sockets

    # A peer that accepts but never replies must read as dead within the ping
    # timeout, not the much longer request timeout.
    listener = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(listener)[2])
    held = Ref{Any}(nothing)
    acceptor = @async (held[] = Sockets.accept(listener))
    elapsed = @elapsed result = REPLicant._ping(port; timeout_seconds = 0.5)
    @test result == false
    @test elapsed < 5
    held[] !== nothing && close(held[])
    close(listener)
end

@testitem "noncompliant_frame_rejected" tags = [:protocol] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # A header with the wrong magic gets an err frame, and the server survives.
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "XXXX")                 # bad magic
        write(sock, REPLicant.PROTOCOL_VERSION)
        write(sock, REPLicant.REQUEST_EVAL)
        write(sock, hton(UInt32(0)))
        flush(sock)
        frame = Utilities.readframe(sock)
        close(sock)
        @test frame.type == REPLicant.RESPONSE_ERR
        @test contains(frame.body, "protocol")

        @test Utilities.request(port, "1 + 1") == "2"
    end
end

@testitem "request_too_large" tags = [:protocol, :limits] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, REPLicant.PROTOCOL_MAGIC)
        write(sock, REPLicant.PROTOCOL_VERSION)
        write(sock, REPLicant.REQUEST_EVAL)
        write(sock, hton(UInt32(REPLicant.MAX_REQUEST_BYTES + 1)))
        flush(sock)
        frame = Utilities.readframe(sock)
        close(sock)
        @test frame.type == REPLicant.RESPONSE_ERR
        @test contains(frame.body, "too large")
    end
end

@testitem "incomplete_body" tags = [:protocol, :limits] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, REPLicant.PROTOCOL_MAGIC)
        write(sock, REPLicant.PROTOCOL_VERSION)
        write(sock, REPLicant.REQUEST_EVAL)
        write(sock, hton(UInt32(10)))   # promise 10 bytes
        write(sock, "abc")              # send only 3, then close
        close(sock)
        # The server logs the incomplete read; the connection is gone so we can
        # only assert the server stays healthy for the next client.
        @test Utilities.request(port, "1 + 1") == "2"
    end
end

@testitem "read_timeout_no_data" tags = [:protocol, :timeout] setup = [Utilities] begin
    import Sockets

    Utilities.withserver(; read_timeout_seconds = 1.0) do server, mod, port
        sock = Sockets.connect(Sockets.localhost, port)
        # Never send a count line.
        response_task = @async String(read(sock))
        sleep(2.5)
        if istaskdone(response_task)
            response = fetch(response_task)
            @test isempty(response) || contains(response, "Read timeout")
        else
            @test !isopen(sock)
        end
        close(sock)
    end
end

@testitem "immediate_eof" tags = [:protocol, :timeout] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # Connect and close without sending anything.
        sock = Sockets.connect(Sockets.localhost, port)
        close(sock)
        sleep(0.1)
        # Server should still serve new connections.
        @test Utilities.request(port, "1 + 1") == "2"
    end
end
