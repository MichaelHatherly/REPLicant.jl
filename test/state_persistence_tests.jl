@testitem "variable_persistence_across_requests" setup = [Utilities] tags =
    [:state_persistence] begin

    import REPLicant

    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "persistent_var = 123") == "123"
        @test @invokelatest isdefined(mod, :persistent_var)
        @test Core.eval(mod, :persistent_var) == 123

        @test Utilities.request(port, "persistent_var + 1") == "124"
        @test Core.eval(mod, :persistent_var) == 123
    end
end

@testitem "function_persistence" setup = [Utilities] tags = [:state_persistence] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        Utilities.request(port, "double(x) = 2x")
        @test @invokelatest isdefined(mod, :double)
        @test @invokelatest(mod.double(21)) == 42

        @test Utilities.request(port, "double(21)") == "42"
    end
end

@testitem "module_loading_persistence" setup = [Utilities] tags = [:state_persistence] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        Utilities.request(port, "using Statistics")
        @test @invokelatest isdefined(mod, :mean)

        @test Utilities.request(port, "mean([3, 5])") == "4.0"
    end
end

@testitem "type_definition_persistence" setup = [Utilities] tags = [:state_persistence] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        Utilities.request(port, "struct MyType x::Int end")
        @test @invokelatest isdefined(mod, :MyType)

        @test contains(Utilities.request(port, "MyType(42)"), "MyType(42)")
        @test Utilities.request(port, "MyType(42).x") == "42"
    end
end

@testitem "mutable_state_modification" setup = [Utilities] tags = [:state_persistence] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        Utilities.request(port, "state = Dict(:counter => 0)")
        @test @invokelatest isdefined(mod, :state)

        for i in 1:3
            @test Utilities.request(port, "state[:counter] += 1") == string(i)
        end

        @test Utilities.request(port, "state[:counter]") == "3"
    end
end

@testitem "global_scope_pollution" setup = [Utilities] tags = [:state_persistence] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        initial_count =
            parse(Int, Utilities.request(port, "length(names(@__MODULE__; all = true))"))

        Utilities.request(port, "test_a = 1; test_b = 2; test_c = 3")

        new_count =
            parse(Int, Utilities.request(port, "length(names(@__MODULE__; all = true))"))
        @test new_count >= initial_count + 3
    end
end
