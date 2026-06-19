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
        response = Utilities.request(port, "undefined_variable")
        @test startswith(response, "ERROR:")
        @test contains(response, "UndefVarError")
    end
end

@testitem "health_noop_empty_request" tags = [:protocol] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        # A zero-length request is the liveness probe: the server replies empty.
        @test Utilities.request(port, "") == ""
    end
end

@testitem "malformed_count_line" tags = [:protocol] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "not-a-number\n")
        flush(sock)
        response = String(read(sock))
        close(sock)
        @test startswith(response, "ERROR:")
        @test contains(response, "Malformed request")
    end
end

@testitem "request_too_large" tags = [:protocol, :limits] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "$(REPLicant.MAX_REQUEST_BYTES + 1)\n")
        flush(sock)
        response = String(read(sock))
        close(sock)
        @test startswith(response, "ERROR:")
        @test contains(response, "too large")
    end
end

@testitem "incomplete_body" tags = [:protocol, :limits] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, "10\n")   # promise 10 bytes
        write(sock, "abc")    # send only 3, then close
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
