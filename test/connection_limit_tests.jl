@testitem "connection_limit_enforcement" tags = [:concurrent, :limits] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver(; max_connections = 2) do server, mod, port
        # Hold two connections open by sending slow requests without reading.
        sock1 =
            Utilities.sendframe(Sockets.connect(Sockets.localhost, port), "sleep(0.5); 1")
        sock2 =
            Utilities.sendframe(Sockets.connect(Sockets.localhost, port), "sleep(0.5); 2")
        sleep(0.1)  # let the server accept and count both

        # Third connection should be rejected at capacity. The server drains the
        # framed request before replying, so the rejection arrives as a reply.
        response3 = Utilities.request(port, "3")
        @test startswith(response3, "Server at capacity")

        # Drain the held connections to free slots.
        @test strip(Utilities.readresp(sock1)) == "1"
        close(sock1)
        @test strip(Utilities.readresp(sock2)) == "2"
        close(sock2)
        sleep(0.1)

        # A new connection should now succeed.
        @test Utilities.request(port, "4") == "4"
    end
end

@testitem "connection_limit_with_rapid_turnover" tags = [:concurrent, :limits] setup =
    [Utilities] begin
    import REPLicant

    Utilities.withserver(; max_connections = 5) do server, mod, port
        rejected_count = Threads.Atomic{Int}(0)
        success_count = Threads.Atomic{Int}(0)
        error_count = Threads.Atomic{Int}(0)

        tasks = map(1:20) do i
            @async begin
                try
                    response = Utilities.request(port, "\"test_$i\"")
                    if startswith(response, "Server at capacity")
                        Threads.atomic_add!(rejected_count, 1)
                    else
                        Threads.atomic_add!(success_count, 1)
                        @test response == "\"test_$i\""
                    end
                catch e
                    @error "Connection error" i error = e
                    Threads.atomic_add!(error_count, 1)
                end
            end
        end

        foreach(wait, tasks)

        # The server drains the framed request before replying, so a capacity
        # rejection always surfaces as a "Server at capacity" reply. Connection
        # errors no longer occur.
        @test error_count[] == 0
        @test success_count[] > 0
        @test success_count[] + rejected_count[] == 20
        @test Utilities.request(port, "1 + 1") == "2"  # server stays responsive
    end
end

@testitem "connection_limit_default_value" tags = [:concurrent, :limits] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        @test server.max_connections == 100
    end
end

@testitem "connection_recovery_after_errors" tags = [:concurrent, :limits] setup =
    [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver(; max_connections = 2) do server, mod, port
        # A request that errors must still free its slot.
        response1 = Utilities.request(port, "undefined_variable")
        @test startswith(response1, "ERROR:")
        sleep(0.1)

        # Two new connections should both succeed.
        sock2 =
            Utilities.sendframe(Sockets.connect(Sockets.localhost, port), "sleep(0.2); 2")
        sock3 =
            Utilities.sendframe(Sockets.connect(Sockets.localhost, port), "sleep(0.2); 3")
        @test strip(Utilities.readresp(sock2)) == "2"
        close(sock2)
        @test strip(Utilities.readresp(sock3)) == "3"
        close(sock3)
    end
end

@testitem "connection_limit_under_concurrent_load" tags = [:concurrent, :limits, :stress] setup =
    [Utilities] begin
    import REPLicant

    # Fire many concurrent requests at a small limit. The server drains every
    # framed request before replying, so each request resolves to either a result
    # or a capacity rejection, never a connection error, and the server stays
    # responsive afterward.
    Utilities.withserver(; max_connections = 5) do server, mod, port
        n = 20
        responses = Channel{String}(n)
        @sync for i in 1:n
            Threads.@spawn try
                put!(responses, strip(Utilities.request(port, "$i")))
            catch error
                put!(responses, "CONNECTION ERROR: $(typeof(error))")
            end
        end
        close(responses)
        collected = collect(responses)

        @test length(collected) == n
        @test !any(r -> startswith(r, "CONNECTION ERROR"), collected)
        @test Utilities.request(port, "\"final\"") == "\"final\""
    end
end
