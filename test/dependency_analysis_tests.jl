@testitem "extract_dependencies_simple" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(function simple_add(x::Int)
        return x + 1
    end))

    func = Core.eval(mod, :simple_add)
    deps = REPLicant._extract_dependencies(func, Tuple{Int64})

    # Simple operations may not show as dependencies in lowered code
    # This is expected behavior - test that function doesn't crash
    @test isa(deps, Vector{String})
end

@testitem "extract_dependencies_with_calls" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(helper(x) = x * 2))
    Core.eval(mod, :(function caller(y)
        return helper(y) + 1
    end))

    func = Core.eval(mod, :caller)
    deps = REPLicant._extract_dependencies(func, Tuple{Any})

    # Should find the call to helper
    @test any(contains(dep, "helper") for dep in deps)
end

@testitem "meta_deps_command_basic" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(function test_deps(x::Int)
        return x + 5
    end))

    thunk = REPLicant._meta_deps_command("test_deps", 1, mod)
    result = thunk()

    @test contains(result, "Dependencies of test_deps")
    @test contains(result, "Method: test_deps(Int64)")
end

@testitem "meta_deps_command_nonexistent" tags = [:dependency_analysis] begin
    mod = Module()

    thunk = REPLicant._meta_deps_command("nonexistent", 1, mod)
    result = thunk()

    @test contains(result, "ERROR: Function nonexistent not found")
end

@testitem "meta_deps_command_not_function" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(test_var = 42))

    thunk = REPLicant._meta_deps_command("test_var", 1, mod)
    result = thunk()

    @test contains(result, "ERROR: test_var is not a function")
end

@testitem "meta_callers_command_basic" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(target_func(x) = x))
    Core.eval(mod, :(caller_func(y) = target_func(y)))

    thunk = REPLicant._meta_callers_command("target_func", 1, mod)
    result = thunk()

    @test contains(result, "Functions that call target_func")
    @test contains(result, "caller_func")
    @test contains(result, "Total callers: 1")
end

@testitem "meta_callers_command_no_callers" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(isolated_func(x) = x + 1))

    thunk = REPLicant._meta_callers_command("isolated_func", 1, mod)
    result = thunk()

    @test contains(result, "No callers found")
    @test contains(result, "Total callers: 0")
end

@testitem "meta_callers_command_nonexistent" tags = [:dependency_analysis] begin
    mod = Module()

    thunk = REPLicant._meta_callers_command("nonexistent", 1, mod)
    result = thunk()

    @test contains(result, "ERROR: Function nonexistent not found")
end

@testitem "function_calls_target_basic" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(target(x) = x))
    Core.eval(mod, :(caller(y) = target(y)))

    caller_func = Core.eval(mod, :caller)
    result = REPLicant._function_calls_target(caller_func, :target, mod)

    @test result == true
end

@testitem "function_calls_target_no_call" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(target(x) = x))
    Core.eval(mod, :(independent(y) = y + 1))

    independent_func = Core.eval(mod, :independent)
    result = REPLicant._function_calls_target(independent_func, :target, mod)

    @test result == false
end

@testitem "meta_graph_command_basic" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(leaf_func(x) = x))
    Core.eval(mod, :(root_func(y) = leaf_func(y)))

    thunk = REPLicant._meta_graph_command("root_func", 1, mod)
    result = thunk()

    @test contains(result, "Call graph starting from root_func")
    @test contains(result, "root_func")
    @test contains(result, "leaf_func")
    @test contains(result, "Nodes in graph:")
end

@testitem "meta_graph_command_nonexistent" tags = [:dependency_analysis] begin
    mod = Module()

    thunk = REPLicant._meta_graph_command("nonexistent", 1, mod)
    result = thunk()

    @test contains(result, "ERROR: Function nonexistent not found")
end

@testitem "meta_uses_command_basic" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(struct MyType
        field::Int
    end))
    Core.eval(mod, :(func_with_type(x::MyType) = x.field))

    thunk = REPLicant._meta_uses_command("MyType", 1, mod)
    result = thunk()

    @test contains(result, "Usage of type MyType")
    @test contains(result, "Functions with MyType in signature")
    @test contains(result, "func_with_type")
end

@testitem "meta_uses_command_nonexistent" tags = [:dependency_analysis] begin
    mod = Module()

    thunk = REPLicant._meta_uses_command("NonexistentType", 1, mod)
    result = thunk()

    @test contains(result, "ERROR: Type NonexistentType not found")
end

@testitem "meta_uses_command_not_type" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(not_a_type = 42))

    thunk = REPLicant._meta_uses_command("not_a_type", 1, mod)
    result = thunk()

    @test contains(result, "ERROR: not_a_type is not a type")
end

@testitem "find_functions_using_type" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(struct TestStruct
        value::Int
    end))
    Core.eval(mod, :(process_struct(s::TestStruct) = s.value))
    Core.eval(mod, :(unrelated_func(x::Int) = x))

    TestStruct = Core.eval(mod, :TestStruct)
    results = REPLicant._find_functions_using_type(TestStruct, mod)

    @test length(results) >= 1
    @test any(first(r) == "process_struct" for r in results)
end

@testitem "type_uses_type_direct" tags = [:dependency_analysis] begin
    @test REPLicant._type_uses_type(Int, Int) == true
    @test REPLicant._type_uses_type(String, Int) == false
end

@testitem "type_uses_type_union" tags = [:dependency_analysis] begin
    @test REPLicant._type_uses_type(Union{Int,String}, Int) == true
    @test REPLicant._type_uses_type(Union{Float64,String}, Int) == false
end

@testitem "type_uses_type_array" tags = [:dependency_analysis] begin
    @test REPLicant._type_uses_type(Vector{Int}, Int) == true
    @test REPLicant._type_uses_type(Vector{String}, Int) == false
end

@testitem "find_types_containing" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(struct Container
        data::Vector{Int}
        count::Int
    end))

    results = REPLicant._find_types_containing(Int, mod)

    @test any(contains(r, "Container.count") for r in results)
end

@testitem "format_method_signature" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(test_func(x::Int, y::String) = x))

    func = Core.eval(mod, :test_func)
    meth = first(methods(func))

    result = REPLicant._format_method_signature(meth)
    @test contains(result, "test_func")
    @test contains(result, "Int64")
    @test contains(result, "String")
end

@testitem "try_get_location" tags = [:dependency_analysis] begin
    mod = Module()
    Core.eval(mod, :(local_func() = 1))

    # Test local function
    result = REPLicant._try_get_location("local_func", mod)
    @test !isnothing(result)

    # Test nonexistent function
    result = REPLicant._try_get_location("nonexistent", mod)
    @test isnothing(result)
end

@testitem "parse_function_name" tags = [:dependency_analysis] begin
    mod = Module()

    # Test simple name
    result = REPLicant._parse_function_name("simple_func", mod)
    @test result == :simple_func

    # Test module qualified name
    result = REPLicant._parse_function_name("Module.func_name", mod)
    @test result == :func_name
end

@testitem "dependency_commands_server_integration" setup = [Utilities] tags =
    [:dependency_analysis] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # Create some functions with dependencies
        sock = Sockets.connect(port)
        println(sock, "base_func(x) = x + 1")
        response = readline(sock)
        close(sock)

        sock = Sockets.connect(port)
        println(sock, "derived_func(y) = base_func(y) * 2")
        response = readline(sock)
        close(sock)

        # Test deps command
        sock = Sockets.connect(port)
        println(sock, "#meta deps derived_func")
        response = readline(sock)
        close(sock)

        @test contains(response, "Dependencies of derived_func")
        @test contains(response, "base_func")

        # Test callers command
        sock = Sockets.connect(port)
        println(sock, "#meta callers base_func")
        response = readline(sock)
        close(sock)

        @test contains(response, "Functions that call base_func")
        @test contains(response, "derived_func")

        # Test graph command
        sock = Sockets.connect(port)
        println(sock, "#meta graph derived_func")
        response = readline(sock)
        close(sock)

        @test contains(response, "Call graph starting from derived_func")
        @test contains(response, "derived_func")
    end
end
