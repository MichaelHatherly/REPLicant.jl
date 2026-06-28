@testitem "syntax_error_handling" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._evaluate("2 + ", 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "ParseError")
end

@testitem "undefined_variable_error" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._evaluate("undefined_var", 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "UndefVarError")
    @test contains(result.output, "undefined_var")
end

@testitem "method_error_handling" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._evaluate("\"hello\" + 5", 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "MethodError")
end

@testitem "division_by_zero_error" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._evaluate("1/0", 1, mod, "")
    @test !result.errored
    @test strip(result.output) == "Inf"  # Julia returns Inf for float division by zero

    # Integer division by zero throws
    result = REPLicant._evaluate("1÷0", 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "DivideError")
end

@testitem "bounds_error_handling" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._evaluate("[1,2,3][5]", 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "BoundsError")
end

@testitem "type_error_handling" tags = [:error_handling] begin
    mod = Module()
    code = """
    x::Int = "not an int"
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "MethodError") || contains(result.output, "TypeError")
end

@testitem "stack_overflow_handling" tags = [:error_handling] begin
    mod = Module()
    code = """
    f() = f()
    f()
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test result.errored
    @test contains(result.output, "StackOverflowError")
end

@testitem "interrupt_is_rethrown_from_capture" tags = [:error_handling] begin
    import REPLicant
    # `_capture` rethrows InterruptException so long-running code stays
    # interruptible instead of being swallowed into a captured result.
    @test_throws InterruptException REPLicant._capture(() -> throw(InterruptException()))
end

@testitem "error_with_backtrace" tags = [:error_handling] begin
    mod = Module()
    code = """
    function foo()
        error("Custom error")
    end
    foo()
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "Custom error")
    # Should have truncated backtrace at top-level scope
    @test contains(result.output, "top-level scope")
end

@testitem "undefined_variable_backtrace_omits_internals" tags = [:error_handling] setup = [Utilities] begin
    import REPLicant
    # Drive the real server path: an undefined top-level binding throws before a
    # `top-level scope` frame exists, so the backtrace must not fall back to dumping
    # REPLicant's eval machinery to the caller.
    Utilities.withserver() do server, mod, port
        body = Utilities.request(port, "undefined_var")
        @test contains(body, "UndefVarError")
        for internal in ("_capture", "with_logstate", "evaluation.jl", "_spawn_worker", "server.jl")
            @test !contains(body, internal)
        end
    end
end

@testitem "ordinary_error_keeps_user_frames" tags = [:error_handling] setup = [Utilities] begin
    import REPLicant
    # An error with a user frame still truncates at `top-level scope`, keeping the
    # user's frames and no eval-entry noise below them.
    Utilities.withserver() do server, mod, port
        body = Utilities.request(port, "f(x) = error(\"boom\"); f(1)")
        @test contains(body, "boom")
        @test contains(body, "f(")
        @test contains(body, "top-level scope")
        @test !contains(body, "_spawn_worker")
        @test !contains(body, "evaluation.jl")
    end
end

@testitem "multiple_errors_in_code" tags = [:error_handling] begin
    mod = Module()
    # Only the first error should be reported
    code = """
    x = undefined_var
    y = another_undefined_var
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test result.errored
    @test startswith(result.output, "ERROR:")
    @test contains(result.output, "undefined_var")
    # Should not get to the second error
    @test !contains(result.output, "another_undefined_var")
end
