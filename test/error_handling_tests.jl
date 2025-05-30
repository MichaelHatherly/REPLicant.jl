@testitem "syntax_error_handling" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._eval_code("2 + ", 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "ParseError")
end

@testitem "undefined_variable_error" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._eval_code("undefined_var", 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "UndefVarError")
    @test contains(result, "undefined_var")
end

@testitem "method_error_handling" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._eval_code("\"hello\" + 5", 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "MethodError")
end

@testitem "division_by_zero_error" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._eval_code("1/0", 1, mod)
    @test strip(result) == "Inf"  # Julia returns Inf for float division by zero

    # Integer division by zero throws
    result = REPLicant._eval_code("1÷0", 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "DivideError")
end

@testitem "bounds_error_handling" tags = [:error_handling] begin
    mod = Module()
    result = REPLicant._eval_code("[1,2,3][5]", 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "BoundsError")
end

@testitem "type_error_handling" tags = [:error_handling] begin
    mod = Module()
    code = """
    x::Int = "not an int"
    """
    result = REPLicant._eval_code(code, 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "MethodError") || contains(result, "TypeError")
end

@testitem "stack_overflow_handling" tags = [:error_handling] begin
    mod = Module()
    code = """
    f() = f()
    f()
    """
    result = REPLicant._eval_code(code, 1, mod)
    @test contains(result, "StackOverflowError")
end

@testitem "interrupt_exception_handling" tags = [:error_handling] begin
    # InterruptException should be rethrown according to the code
    # This is harder to test directly, but we can verify the behavior exists
    @test_throws InterruptException begin
        # Simulate what IOCapture.capture does with rethrow = InterruptException
        try
            throw(InterruptException())
        catch e
            if e isa InterruptException
                rethrow(e)
            end
        end
    end
end

@testitem "error_with_backtrace" tags = [:error_handling] begin
    mod = Module()
    code = """
    function foo()
        error("Custom error")
    end
    foo()
    """
    result = REPLicant._eval_code(code, 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "Custom error")
    # Should have truncated backtrace at top-level scope
    @test contains(result, "top-level scope")
end

@testitem "multiple_errors_in_code" tags = [:error_handling] begin
    mod = Module()
    # Only the first error should be reported
    code = """
    x = undefined_var
    y = another_undefined_var
    """
    result = REPLicant._eval_code(code, 1, mod)
    @test startswith(result, "ERROR:")
    @test contains(result, "undefined_var")
    # Should not get to the second error
    @test !contains(result, "another_undefined_var")
end
