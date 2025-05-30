@testitem "eval_simple_arithmetic" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._eval_code("2 + 2", 1, mod)
    @test strip(result) == "4"
end

@testitem "eval_with_output" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    println("Hello")
    42
    """
    result = REPLicant._eval_code(code, 1, mod)
    lines = split(strip(result), '\n')
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
    result = REPLicant._eval_code(code, 1, mod)
    @test strip(result) == "30"
end

@testitem "eval_function_definition" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    function greet(name)
        "Hello, \$(name)!"
    end
    greet("World")
    """
    result = REPLicant._eval_code(code, 1, mod)
    @test strip(result) == "\"Hello, World!\""
end

@testitem "eval_using_packages" tags = [:code_evaluation] begin
    mod = Module()
    # Test loading a standard library package
    code = """
    using Statistics
    mean([1, 2, 3, 4, 5])
    """
    result = REPLicant._eval_code(code, 1, mod)
    @test strip(result) == "3.0"
end

@testitem "eval_empty_code" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._eval_code("", 1, mod)
    @test strip(result) == "nothing"
end

@testitem "eval_nothing_result" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._eval_code("nothing", 1, mod)
    @test strip(result) == "nothing"
end

@testitem "eval_array_display" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._eval_code("[1, 2, 3]", 1, mod)
    @test contains(result, "3-element Vector{Int64}")
    @test contains(result, "1")
    @test contains(result, "2")
    @test contains(result, "3")
end

@testitem "eval_dict_display" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._eval_code("Dict(:a => 1, :b => 2)", 1, mod)
    @test contains(result, "Dict{Symbol, Int64}")
    @test contains(result, ":a => 1") || contains(result, ":b => 2")
end

@testitem "eval_string_with_quotes" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._eval_code("\"Hello \\\"World\\\"\"", 1, mod)
    @test strip(result) == "\"Hello \\\"World\\\"\""
end
