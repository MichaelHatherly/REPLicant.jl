@testitem "parse_call_expression_no_args" tags = [:performance_introspection] begin
    mod = Module()
    func_name, arg_types = REPLicant._parse_call_expression("myfunction ()", mod)
    @test func_name == :myfunction
    @test arg_types == Tuple{}
end

@testitem "parse_call_expression_single_type" tags = [:performance_introspection] begin
    mod = Module()
    func_name, arg_types = REPLicant._parse_call_expression("test_func (Int,)", mod)
    @test func_name == :test_func
    @test arg_types == Tuple{Int64}
end

@testitem "parse_call_expression_multiple_types" tags = [:performance_introspection] begin
    mod = Module()
    func_name, arg_types =
        REPLicant._parse_call_expression("process (Int, Float64, String)", mod)
    @test func_name == :process
    @test arg_types == Tuple{Int64,Float64,String}
end

@testitem "parse_call_expression_invalid_syntax" tags = [:performance_introspection] begin
    mod = Module()
    @test_throws ErrorException REPLicant._parse_call_expression("bad syntax", mod)
end

@testitem "meta_typed_basic" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(function simple_add(x::Int, y::Int)
        return x + y
    end))

    thunk = REPLicant._meta_typed_command("simple_add (Int, Int)", 1, mod)
    result = thunk()

    @test contains(result, "Type-inferred code")
    @test contains(result, "simple_add")
    @test contains(result, "Return type: Int64")
end

@testitem "meta_typed_nonexistent_function" tags = [:performance_introspection] begin
    mod = Module()

    thunk = REPLicant._meta_typed_command("nonexistent (Int,)", 1, mod)
    @test_throws ErrorException thunk()
end

@testitem "meta_warntype_stable" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(function stable_multiply(x::Float64)
        return x * 2.0
    end))

    thunk = REPLicant._meta_warntype_command("stable_multiply (Float64,)", 1, mod)
    result = thunk()

    @test contains(result, "Type stability analysis")
    @test contains(result, "✓ No type stability issues detected")
end

@testitem "meta_warntype_unstable" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(function unstable_func(x::Int)
        if x > 0
            return x
        else
            return "negative"
        end
    end))

    thunk = REPLicant._meta_warntype_command("unstable_func (Int,)", 1, mod)
    result = thunk()

    @test contains(result, "Type stability analysis")
    @test contains(result, "## Type Stability Issues")
    @test contains(result, "Return type is unstable")
end

@testitem "meta_llvm_basic" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(function simple_shift(x::Int)
        return x << 1
    end))

    thunk = REPLicant._meta_llvm_command("simple_shift (Int,)", 1, mod)
    result = thunk()

    @test contains(result, "LLVM IR")
    @test contains(result, "## LLVM Analysis")
    @test contains(result, "Stack allocations:")
    @test contains(result, "Function calls:")
end

@testitem "meta_native_basic" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(function simple_add(x::Int, y::Int)
        return x + y
    end))

    thunk = REPLicant._meta_native_command("simple_add (Int, Int)", 1, mod)
    result = thunk()

    @test contains(result, "Native assembly")
    # Platform-specific assembly, just check header exists
    @test !isempty(result)
end

@testitem "meta_optimize_stable_function" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(function optimized_sum(arr::Vector{Float64})
        s = 0.0
        for x in arr
            s += x
        end
        return s
    end))

    thunk = REPLicant._meta_optimize_command("optimized_sum (Vector{Float64},)", 1, mod)
    result = thunk()

    @test contains(result, "Performance Analysis")
    @test contains(result, "Type Inference")
    @test contains(result, "Return type: Float64")
    @test contains(result, "Type stable: ✓ Yes")
    @test contains(result, "✓ No major performance issues detected")
end

@testitem "meta_optimize_unstable_function" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(function unoptimized_process(x)
        if x > 0
            return x * 2
        else
            return "invalid"
        end
    end))

    thunk = REPLicant._meta_optimize_command("unoptimized_process (Any,)", 1, mod)
    result = thunk()

    @test contains(result, "Performance Analysis")
    @test contains(result, "Type stable: ✗ No")
    @test contains(result, "Optimization Suggestions")
end

@testitem "meta_command_performance_subcommands" tags = [:performance_introspection] begin
    mod = Module()
    Core.eval(mod, :(test_perf(x::Int) = x * 2))

    # Test typed subcommand
    thunk = REPLicant._meta_command("typed test_perf (Int,)", 1, mod)
    result = thunk()
    @test contains(result, "Type-inferred code")

    # Test warntype subcommand
    thunk = REPLicant._meta_command("warntype test_perf (Int,)", 1, mod)
    result = thunk()
    @test contains(result, "Type stability analysis")

    # Test llvm subcommand
    thunk = REPLicant._meta_command("llvm test_perf (Int,)", 1, mod)
    result = thunk()
    @test contains(result, "LLVM IR")

    # Test native subcommand
    thunk = REPLicant._meta_command("native test_perf (Int,)", 1, mod)
    result = thunk()
    @test contains(result, "Native assembly")

    # Test optimize subcommand
    thunk = REPLicant._meta_command("optimize test_perf (Int,)", 1, mod)
    result = thunk()
    @test contains(result, "Performance Analysis")
end

@testitem "highlight_type_instabilities" tags = [:performance_introspection] begin
    # Test with stable code
    stable_output = """
    Body::Int64
    1 ─ %1 = x + y
    └──      return %1
    """

    result = REPLicant._highlight_type_instabilities(stable_output)
    @test contains(result, "✓ No type stability issues detected")

    # Test with unstable code
    unstable_output = """
    Body::ANY
    1 ─ %1 = x::Int64
    2 ─ %2 = result::ANY
    3 ─ %3 = Box(value)
    """

    result = REPLicant._highlight_type_instabilities(unstable_output)
    @test contains(result, "## Type Stability Issues")
    @test contains(result, "Return type is unstable")
    @test contains(result, "Type instability")
    @test contains(result, "Boxing allocation")
end

@testitem "extract_performance_issues" tags = [:performance_introspection] begin
    # Test extraction from warntype output
    output = """
    Body::ANY
    1 ─ %1 = value::Any
    2 ─ %2 = data::Union{Int64, Nothing}
    3 ─ %3 = Box(temp)
    """

    issues = REPLicant._extract_performance_issues(output)

    @test length(issues) >= 3
    @test any(contains(issue, "returns unstable type") for issue in issues)
    @test any(contains(issue, "Variable 'value' has unstable type") for issue in issues)
    @test any(contains(issue, "union type") for issue in issues)
end

@testitem "generate_optimization_suggestions" tags = [:performance_introspection] begin
    # Test with type instability issues
    issues = ["Variable 'x' has unstable type Any", "Function returns unstable type (Any)"]

    suggestions = REPLicant._generate_optimization_suggestions(issues, "")

    @test length(suggestions) >= 2
    @test any(contains(s, "type assertions") for s in suggestions)
    @test any(contains(s, "splitting polymorphic") for s in suggestions)

    # Test with union type issues
    issues = ["Variable 'data' has union type: Union{Int64, Nothing}"]

    suggestions = REPLicant._generate_optimization_suggestions(issues, "")

    @test any(contains(s, "Nothing/Missing") for s in suggestions)
    @test any(contains(s, "Union splitting") for s in suggestions)
end

@testitem "performance_commands_server_integration" setup = [Utilities] tags =
    [:performance_introspection] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # Create a test function in the server
        sock = Sockets.connect(port)
        println(sock, "perf_test(x::Int) = x + 1")
        response = readline(sock)
        close(sock)

        # Test typed command through server
        sock = Sockets.connect(port)
        println(sock, "#meta typed perf_test (Int,)")
        response = readline(sock)
        close(sock)

        @test contains(response, "Type-inferred code")
        @test contains(response, "Return type: Int64")

        # Test warntype command through server
        sock = Sockets.connect(port)
        println(sock, "#meta warntype perf_test (Int,)")
        response = readline(sock)
        close(sock)

        @test contains(response, "Type stability analysis")
        @test contains(response, "✓ No type stability issues detected")
    end
end
