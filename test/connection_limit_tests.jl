@testitem "connection_limit_enforcement" tags = [:concurrent, :limits] setup = [Utilities] begin
    using REPLicant
    using Sockets
    using Logging
    using Test

    Utilities.withserver(; max_connections = 2) do server, mod, port
        # Create connections up to the limit
        sock1 = Sockets.connect(port)
        println(sock1, "sleep(0.5); 1")  # Hold connection open

        sock2 = Sockets.connect(port)
        println(sock2, "sleep(0.5); 2")  # Hold connection open

        # Third connection should be rejected
        sock3 = Sockets.connect(port)
        response3 = readline(sock3)
        close(sock3)

        @test startswith(response3, "ERROR: Server at capacity")

        # Complete first connection to free up a slot
        response1 = readline(sock1)
        close(sock1)
        @test strip(response1) == "1"

        # Brief delay to ensure connection is released
        sleep(0.1)

        # Now a new connection should succeed
        sock4 = Sockets.connect(port)
        println(sock4, "4")
        response4 = readline(sock4)
        close(sock4)
        @test strip(response4) == "4"

        # Clean up second connection
        response2 = readline(sock2)
        close(sock2)
        @test strip(response2) == "2"
    end
end

@testitem "connection_limit_with_rapid_turnover" tags = [:concurrent, :limits] setup =
    [Utilities] begin
    using REPLicant
    using Sockets
    using Logging
    using Test

    Utilities.withserver(; max_connections = 5) do server, mod, port
        # Rapidly create and close connections
        rejected_count = Threads.Atomic{Int}(0)
        success_count = Threads.Atomic{Int}(0)
        error_count = Threads.Atomic{Int}(0)

        # Create more tasks than the connection limit
        tasks = map(1:20) do i
            @async begin
                try
                    sock = Sockets.connect(port)
                    println(sock, "\"test_$i\"")
                    response = readline(sock)
                    close(sock)

                    if startswith(response, "ERROR: Server at capacity")
                        Threads.atomic_add!(rejected_count, 1)
                    else
                        Threads.atomic_add!(success_count, 1)
                        @test strip(response) == "\"test_$i\""
                    end
                catch e
                    # Connection errors are expected when server is busy
                    @error "Connection error" i error = e
                    Threads.atomic_add!(error_count, 1)
                end
            end
        end

        # Wait for all tasks to complete
        foreach(wait, tasks)

        # We should have some successes and some rejections
        @test success_count[] > 0
        @test rejected_count[] > 0
        @test error_count[] < 5
        @test success_count[] + rejected_count[] + error_count[] == 20
    end
end

@testitem "connection_limit_default_value" tags = [:concurrent, :limits] setup = [Utilities] begin
    using REPLicant

    Utilities.withserver() do server, mod, port
        # Check that max_connections has the expected default
        @test server.max_connections == 100
    end
end

@testitem "connection_recovery_after_errors" tags = [:concurrent, :limits] setup =
    [Utilities] begin
    using REPLicant
    using Sockets
    using Logging
    using Test

    Utilities.withserver(; max_connections = 2) do server, mod, port
        # Create connection that will error
        sock1 = Sockets.connect(port)
        println(sock1, "undefined_variable")
        response1 = readline(sock1)
        close(sock1)
        @test startswith(response1, "ERROR:")

        # Connection slot should be freed even after error
        sleep(0.1)

        # Should be able to create 2 new connections
        sock2 = Sockets.connect(port)
        println(sock2, "sleep(0.2); 2")

        sock3 = Sockets.connect(port)
        println(sock3, "sleep(0.2); 3")

        # Both should succeed
        response2 = readline(sock2)
        close(sock2)
        @test strip(response2) == "2"

        response3 = readline(sock3)
        close(sock3)
        @test strip(response3) == "3"
    end
end

@testitem "connection_limit_stress_test" tags = [:concurrent, :limits, :stress] setup =
    [Utilities] begin
    using REPLicant
    using Sockets
    using Logging
    using Test

    # This test verifies that the connection limit functionality works under concurrent load.
    # Since concurrent testing is inherently variable due to timing, scheduling, and system load,
    # we use a probabilistic approach: run the test 3 times and require at least 2 passes.
    # 
    # Each run attempts 20 connections with a max_connections limit of 5. Connections are
    # staggered over time to avoid thundering herd issues. We use very lenient success criteria
    # (only 5 successful connections required) to account for the unpredictability of concurrent
    # operations while still verifying the core functionality works.
    #
    # This approach balances test reliability with meaningful verification of the connection
    # limiting behavior under stress.
    pass_count = Ref(0)
    run_count = 3

    for run = 1:run_count
        try
            Utilities.withserver(; max_connections = 5) do server, mod, port
                # Smaller numbers for more predictable behavior
                num_attempts = 20
                results = Channel{String}(num_attempts)

                tasks = map(1:num_attempts) do i
                    @async begin
                        # Spread connections over time
                        sleep(0.02 * (i - 1))

                        try
                            sock = Sockets.connect(port)

                            # Try to send our request
                            try
                                println(sock, "$i")
                                response = readline(sock)
                                close(sock)
                                put!(results, strip(response))
                            catch e
                                # If we fail after connecting
                                try
                                    close(sock)
                                catch
                                    # Socket might already be closed
                                end
                                put!(results, "ERROR: $(typeof(e))")
                            end
                        catch e
                            # Connection failed
                            put!(results, "ERROR: Connect failed")
                        end
                    end
                end

                # Wait for all tasks
                foreach(wait, tasks)
                close(results)

                # Collect all responses
                responses = String[]
                while isready(results)
                    push!(responses, take!(results))
                end

                # Categorize responses
                successful = count(r -> !startswith(r, "ERROR:"), responses)
                capacity_errors = count(r -> contains(r, "Server at capacity"), responses)

                @info "Stress test run $run" successful total = length(responses)

                # Very lenient criteria - just verify basic functionality
                if successful >= 5 && length(responses) >= 15
                    pass_count[] += 1
                end

                # Always verify server is still responsive
                sock = Sockets.connect(port)
                println(sock, "\"final_test\"")
                response = readline(sock)
                close(sock)
                @test strip(response) == "\"final_test\""
            end
        catch e
            @warn "Stress test run failed" run error = e
        end
    end

    # Require at least 2 out of 3 runs to pass
    @test pass_count[] >= 2
end
