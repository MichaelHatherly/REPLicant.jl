@testitem "multiple_concurrent_clients" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        results = Channel{String}(5)

        tasks = map(1:5) do i
            @async begin
                try
                    put!(results, Utilities.request(port, "$i * $i"))
                catch e
                    @warn "Connection error in concurrent test" i error = e
                    put!(results, "ERROR: $e")
                end
            end
        end

        foreach(wait, tasks)
        close(results)

        responses = collect(results)
        @test length(responses) == 5

        successful_responses = filter(r -> !startswith(r, "ERROR:"), responses)
        @test length(successful_responses) >= 3

        actual = Set(strip.(successful_responses))
        expected_values = Set(["1", "4", "9", "16", "25"])
        @test issubset(actual, expected_values)
    end
end

@testitem "concurrent_state_isolation" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "test_var = 42") == "42"
        @test Utilities.request(port, "test_var") == "42"
    end
end

@testitem "rapid_connections" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        for i in 1:20
            @test Utilities.request(port, "1") == "1"
        end
    end
end

@testitem "client_disconnect_handling" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Connect and immediately disconnect.
        sock = Sockets.connect(Sockets.localhost, port)
        close(sock)
        sleep(0.1)

        @test Utilities.request(port, "1 + 1") == "2"
    end
end

@testitem "concurrent_long_running_tasks" tags = [:concurrent] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        task1 = @async Utilities.request(port, "sleep(0.5); \"done1\"")

        sleep(0.1)  # let the long task start
        @test Utilities.request(port, "\"quick\"") == "\"quick\""

        @test fetch(task1) == "\"done1\""
    end
end
