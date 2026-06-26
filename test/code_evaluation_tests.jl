@testitem "eval_simple_arithmetic" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("2 + 2", 1, mod)
    @test !result.errored
    @test strip(result.output) == "4"
end

@testitem "eval_with_output" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    println("Hello")
    42
    """
    result = REPLicant._evaluate(code, 1, mod)
    lines = split(strip(result.output), '\n')
    @test length(lines) == 2
    @test lines[1] == "Hello"
    @test lines[2] == "42"
end

@testitem "eval_multiline_code" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    x = 10
    y = 20
    x + y
    """
    result = REPLicant._evaluate(code, 1, mod)
    @test strip(result.output) == "30"
end

@testitem "eval_function_definition" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    function greet(name)
        "Hello, \$(name)!"
    end
    greet("World")
    """
    result = REPLicant._evaluate(code, 1, mod)
    @test strip(result.output) == "\"Hello, World!\""
end

@testitem "eval_using_packages" tags = [:code_evaluation] begin
    mod = Module()
    # Test loading a standard library package
    code = """
    using Statistics
    mean([1, 2, 3, 4, 5])
    """
    result = REPLicant._evaluate(code, 1, mod)
    @test strip(result.output) == "3.0"
end

@testitem "eval_empty_code" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("", 1, mod)
    @test !result.errored
    @test strip(result.output) == ""
end

@testitem "eval_nothing_result" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("nothing", 1, mod)
    @test strip(result.output) == ""
end

@testitem "eval_non_nothing_value_echoes" tags = [:code_evaluation] begin
    mod = Module()
    # Only `nothing` is suppressed; other falsy-looking values still echo.
    @test strip(REPLicant._evaluate("missing", 1, mod).output) == "missing"
    @test strip(REPLicant._evaluate("0", 1, mod).output) == "0"
    @test strip(REPLicant._evaluate("\"\"", 1, mod).output) == "\"\""
end

@testitem "eval_array_display" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("[1, 2, 3]", 1, mod)
    @test contains(result.output, "3-element Vector{Int64}")
    @test contains(result.output, "1")
    @test contains(result.output, "2")
    @test contains(result.output, "3")
end

@testitem "eval_dict_display" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("Dict(:a => 1, :b => 2)", 1, mod)
    @test contains(result.output, "Dict{Symbol, Int64}")
    @test contains(result.output, ":a => 1") || contains(result.output, ":b => 2")
end

@testitem "eval_string_with_quotes" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("\"Hello \\\"World\\\"\"", 1, mod)
    @test strip(result.output) == "\"Hello \\\"World\\\"\""
end

@testitem "eval_display_output_is_captured" tags = [:code_evaluation] begin
    mod = Module()
    # `display(x)` writes through the display stack, not stdout; it must still be
    # captured alongside ordinary printed output.
    result = REPLicant._evaluate("display([1, 2, 3]); println(\"after\")", 1, mod)
    @test contains(result.output, "3-element Vector{Int64}")
    @test contains(result.output, "after")
end
