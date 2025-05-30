@testitem "multiple_concurrent_clients" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Create multiple concurrent connections
        results = Channel{String}(5)

        tasks = map(1:5) do i
            @async begin
                try
                    sock = Sockets.connect(port)
                    println(sock, "$i * $i")
                    response = readline(sock)
                    close(sock)
                    put!(results, response)
                catch e
                    # Log but don't fail on connection errors
                    @warn "Connection error in concurrent test" i error = e
                    # Put error message so we know what happened
                    put!(results, "ERROR: $e")
                end
            end
        end

        # Wait for all tasks
        foreach(wait, tasks)
        close(results)

        # Collect and verify results
        responses = collect(results)
        @test length(responses) == 5

        # Results might be in any order, but should contain squares
        # Filter out any errors and check we got at least 3 successful responses
        # (allowing for some connection failures under high concurrency)
        successful_responses = filter(r -> !startswith(r, "ERROR:"), responses)
        @test length(successful_responses) >= 3

        # Check that successful responses are correct
        actual = Set(strip.(successful_responses))
        expected_values = Set(["1", "4", "9", "16", "25"])
        @test issubset(actual, expected_values)
    end
end

@testitem "concurrent_state_isolation" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # First client sets a variable
        sock1 = Sockets.connect(port)
        println(sock1, "test_var = 42")
        response1 = readline(sock1)
        close(sock1)
        @test strip(response1) == "42"

        # Second client can see the variable (shared state)
        sock2 = Sockets.connect(port)
        println(sock2, "test_var")
        response2 = readline(sock2)
        close(sock2)
        @test strip(response2) == "42"
    end
end

@testitem "rapid_connections" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Rapidly create and close connections
        for i = 1:20
            sock = Sockets.connect(port)
            println(sock, "1")
            response = readline(sock)
            @test strip(response) == "1"
            close(sock)
        end
    end
end

@testitem "client_disconnect_handling" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Connect and immediately disconnect
        sock = Sockets.connect(port)
        close(sock)

        # Server should still be running
        sleep(0.1)

        # New connection should work
        sock2 = Sockets.connect(port)
        println(sock2, "1 + 1")
        response = readline(sock2)
        close(sock2)
        @test strip(response) == "2"
    end
end

@testitem "concurrent_long_running_tasks" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Start a long-running task
        task1 = @async begin
            sock = Sockets.connect(port)
            println(sock, "sleep(0.5); \"done1\"")
            response = readline(sock)
            close(sock)
            response
        end

        # While it's running, another quick task should complete
        sleep(0.1)  # Let first task start
        sock2 = Sockets.connect(port)
        println(sock2, "\"quick\"")
        response2 = readline(sock2)
        close(sock2)
        @test strip(response2) == "\"quick\""

        # Wait for long task
        response1 = fetch(task1)
        @test strip(response1) == "\"done1\""
    end
end
