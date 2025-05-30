@testitem "basic_socket_communication" tags = [:protocol] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Connect and send simple command
        sock = Sockets.connect(port)
        println(sock, "2 + 2")
        response = readline(sock)
        close(sock)

        @test strip(response) == "4"
    end
end

@testitem "empty_request_handling" tags = [:protocol] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(port)
        println(sock, "")  # Empty line
        response = readline(sock)
        close(sock)

        @test strip(response) == "nothing"
    end
end

@testitem "whitespace_handling" tags = [:protocol] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Test with leading/trailing whitespace
        sock = Sockets.connect(port)
        println(sock, "   3 + 3   ")
        response = readline(sock)
        close(sock)

        @test strip(response) == "6"
    end
end

@testitem "newline_in_strings" tags = [:protocol] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # String with escaped newline should work
        sock = Sockets.connect(port)
        println(sock, "\"Hello\\nWorld\"")
        response = readline(sock)
        close(sock)

        @test strip(response) == "\"Hello\\nWorld\""
    end
end

@testitem "basic_unicode" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Basic Unicode support check
        sock = Sockets.connect(port)
        println(sock, "\"π\"")
        response = readline(sock)
        close(sock)

        @test strip(response) == "\"π\""
    end
end

@testitem "large_output_handling" tags = [:protocol] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Generate large output
        sock = Sockets.connect(port)
        println(sock, "collect(1:1000)")
        response = readline(sock)
        close(sock)

        # Should contain truncation indicator
        @test contains(response, "1000-element Vector{Int64}")
    end
end

@testitem "error_response_format" tags = [:protocol] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(port)
        println(sock, "undefined_variable")
        response = readline(sock)
        close(sock)

        # Error responses should start with ERROR:
        @test startswith(response, "ERROR:")
        @test contains(response, "UndefVarError")
    end
end

@testitem "multiple_requests_per_connection" tags = [:protocol] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(port)

        # Send first request
        println(sock, "1 + 1")
        response1 = readline(sock)
        @test strip(response1) == "2"

        # Connection should be closed after first request
        # Check if socket is still open
        @test !isopen(sock) || eof(sock)

        close(sock)
    end
end

@testitem "read_timeout_no_newline" tags = [:protocol, :timeout] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver(; read_timeout_seconds = 1.0) do server, mod, port
        sock = Sockets.connect(port)

        # Send data without newline - should timeout
        print(sock, "incomplete_line_without_newline")
        flush(sock)

        # Create a task to read the response with its own timeout
        read_task = @async begin
            try
                readline(sock)
            catch e
                "ERROR: $(e)"
            end
        end

        # Wait for either response or timeout (with buffer)
        sleep(2.0)

        if istaskdone(read_task)
            response = fetch(read_task)
            @test contains(response, "ERROR:") || contains(response, "Read timeout")
        else
            # The read is still blocked, which means the server closed the connection
            @test !isopen(sock)
        end

        close(sock)
    end
end

@testitem "line_length_limit" tags = [:protocol, :limits] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(port)

        # Try to send a line that exceeds 1MB limit
        # Create a string that's just over 1MB
        large_string = "x"^(1024 * 1024 + 100)

        # Send the oversized line
        print(sock, large_string)
        println(sock)  # Add newline
        flush(sock)

        # Should get an error response
        response = readline(sock)

        @test startswith(response, "ERROR:")
        @test contains(response, "Line too long") || contains(response, "exceeds maximum")

        close(sock)
    end
end

@testitem "valid_long_line" tags = [:protocol, :limits] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(port)

        # Send a long but valid line (under 1MB)
        # Create a string that's about 100KB
        medium_string = "Symbol(\"" * ("x"^(100 * 1024)) * "\")"

        println(sock, medium_string)
        response = readline(sock)
        close(sock)

        # Should process normally
        @test !startswith(response, "ERROR:")
        @test length(response) > 100000  # Response should include the large string
    end
end

@testitem "immediate_eof" tags = [:protocol, :timeout] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(port)

        # Close immediately without sending anything
        close(sock)

        # Server should handle gracefully
        # Give server a moment to process the disconnection
        sleep(0.1)

        # Server should still be running and accept new connections
        sock2 = Sockets.connect(port)
        println(sock2, "1 + 1")
        response = readline(sock2)
        close(sock2)

        @test strip(response) == "2"
    end
end
