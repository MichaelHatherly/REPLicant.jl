@testitem "variable_persistence_across_requests" setup = [Utilities] tags =
    [:state_persistence] begin

    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Set a variable
        sock1 = Sockets.connect(port)
        println(sock1, "persistent_var = 123")
        response1 = readline(sock1)
        close(sock1)
        @test strip(response1) == "123"
        @test isdefined(mod, :persistent_var)
        @test mod.persistent_var == 123

        # Access it in another request
        sock2 = Sockets.connect(port)
        println(sock2, "persistent_var + 1")
        response2 = readline(sock2)
        close(sock2)
        @test strip(response2) == "124"
        @test mod.persistent_var == 123
    end
end

@testitem "function_persistence" setup = [Utilities] tags = [:state_persistence] begin

    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Define a function
        sock1 = Sockets.connect(port)
        println(sock1, "double(x) = 2x")
        response1 = readline(sock1)
        close(sock1)
        @test isdefined(mod, :double)
        @test @invokelatest(mod.double(21)) == 42

        # Use it in another request
        sock2 = Sockets.connect(port)
        println(sock2, "double(21)")
        response2 = readline(sock2)
        close(sock2)
        @test strip(response2) == "42"
    end
end

@testitem "module_loading_persistence" setup = [Utilities] tags = [:state_persistence] begin

    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Load a module
        sock1 = Sockets.connect(port)
        println(sock1, "using Statistics")
        response1 = readline(sock1)
        close(sock1)
        @test isdefined(mod, :mean)

        # Use function from that module
        sock2 = Sockets.connect(port)
        println(sock2, "mean([3, 5])")
        response2 = readline(sock2)
        close(sock2)
        @test strip(response2) == "4.0"
    end
end

@testitem "type_definition_persistence" setup = [Utilities] tags = [:state_persistence] begin

    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Define a type
        sock1 = Sockets.connect(port)
        println(sock1, "struct MyType x::Int end")
        response1 = readline(sock1)
        close(sock1)
        @test isdefined(mod, :MyType)

        # Create instance in another request
        sock2 = Sockets.connect(port)
        println(sock2, "MyType(42)")
        response2 = readline(sock2)
        close(sock2)
        @test contains(response2, "MyType(42)")

        # Access field in third request
        sock3 = Sockets.connect(port)
        println(sock3, "MyType(42).x")
        response3 = readline(sock3)
        close(sock3)
        @test strip(response3) == "42"
    end
end

@testitem "mutable_state_modification" setup = [Utilities] tags = [:state_persistence] begin

    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Create mutable container
        sock1 = Sockets.connect(port)
        println(sock1, "state = Dict(:counter => 0)")
        response1 = readline(sock1)
        close(sock1)
        @test isdefined(mod, :state)

        # Modify it multiple times
        for i = 1:3
            sock = Sockets.connect(port)
            println(sock, "state[:counter] += 1")
            response = readline(sock)
            close(sock)
            @test strip(response) == string(i)
        end

        # Verify final state
        sock_final = Sockets.connect(port)
        println(sock_final, "state[:counter]")
        response_final = readline(sock_final)
        close(sock_final)
        @test strip(response_final) == "3"
    end
end

@testitem "global_scope_pollution" setup = [Utilities] tags = [:state_persistence] begin

    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Get initial variable count
        sock1 = Sockets.connect(port)
        println(sock1, "length(names(@__MODULE__; all = true))")
        response1 = readline(sock1)
        close(sock1)
        initial_count = parse(Int, strip(response1))

        # Add some variables
        sock2 = Sockets.connect(port)
        println(sock2, "test_a = 1; test_b = 2; test_c = 3")
        response2 = readline(sock2)
        close(sock2)

        # Check new count
        sock3 = Sockets.connect(port)
        println(sock3, "length(names(@__MODULE__; all = true))")
        response3 = readline(sock3)
        close(sock3)
        new_count = parse(Int, strip(response3))

        # Should have added at least 3 new names
        @test new_count >= initial_count + 3
    end
end
