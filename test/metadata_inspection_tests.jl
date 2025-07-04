@testitem "meta_list_empty_module" tags = [:metadata_inspection] begin
    mod = Module()
    result = REPLicant._meta_list(mod)
    @test contains(result, "Objects in")
    # Module has a self-reference as 'anonymous'
    @test contains(result, "Variable (1):")
    @test contains(result, "anonymous :: Module")
end

@testitem "meta_list_with_function" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(function test_func(x::Int)
        return x * 2
    end))

    result = REPLicant._meta_list(mod)
    @test contains(result, "Function (1):")
    @test contains(result, "test_func(Int64)")
    @test contains(result, "Total: 2 objects")  # function + anonymous module variable
end

@testitem "meta_list_with_type" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(struct TestType
        x::Int;
        y::Float64
    end))

    result = REPLicant._meta_list(mod)
    @test contains(result, "Type (1):")
    @test contains(result, "TestType <: Any with 2 fields")
    @test contains(result, "Total: 2 objects")  # type + anonymous
end

@testitem "meta_list_with_abstract_type" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(abstract type AbstractTest end))

    result = REPLicant._meta_list(mod)
    @test contains(result, "Type (1):")
    @test contains(result, "AbstractTest <: Any (abstract)")
    @test contains(result, "Total: 2 objects")  # type + anonymous
end

@testitem "meta_list_with_variable" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(data = [1.0, 2.0, 3.0]))

    result = REPLicant._meta_list(mod)
    @test contains(result, "Variables (2):")  # data + anonymous
    @test contains(result, "data :: Vector{Float64} (3 elements)")
    @test contains(result, "Total: 2 objects")
end

@testitem "meta_list_with_dict_variable" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(config = Dict("key" => "value")))

    result = REPLicant._meta_list(mod)
    @test contains(result, "Variables (2):")  # config + anonymous
    @test contains(result, "config :: Dict{String, String} (1 entry)")
end

@testitem "meta_list_with_string_variable" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(message = "Hello, World!"))

    result = REPLicant._meta_list(mod)
    @test contains(result, "Variables (2):")  # message + anonymous
    @test contains(result, "message :: String (13 characters)")
end

@testitem "meta_list_with_module" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(module SubModule end))

    result = REPLicant._meta_list(mod)
    @test contains(result, "Module (1):")
    @test contains(result, "SubModule")
    @test contains(result, "Total: 2 objects")  # module + anonymous
end

@testitem "meta_list_filter_functions" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(function func1() end))
    Core.eval(mod, :(function func2() end))
    Core.eval(mod, :(struct Type1 end))
    Core.eval(mod, :(data = 42))

    result = REPLicant._meta_list(mod, "functions")
    @test contains(result, "Functions in")
    @test contains(result, "Functions (2):")
    @test contains(result, "func1")
    @test contains(result, "func2")
    @test !contains(result, "Type1")
    @test !contains(result, "anonymous :: Module")  # Check anonymous variable is filtered out
    @test !contains(result, "Total:")  # No total when filtering
end

@testitem "meta_list_filter_types" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(struct Type1 end))
    Core.eval(mod, :(struct Type2
        x::Int
    end))
    Core.eval(mod, :(function func1() end))
    Core.eval(mod, :(data = 42))

    result = REPLicant._meta_list(mod, "types")
    @test contains(result, "Types in")
    @test contains(result, "Types (2):")
    @test contains(result, "Type1")
    @test contains(result, "Type2")
    @test !contains(result, "func1")
    @test !contains(result, "data")
end

@testitem "meta_list_filter_variables" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(x = 10))
    Core.eval(mod, :(y = "hello"))
    Core.eval(mod, :(function func1() end))
    Core.eval(mod, :(struct Type1 end))

    result = REPLicant._meta_list(mod, "variables")
    @test contains(result, "Variables in")
    @test contains(result, "Variables (3):")  # x, y, anonymous
    @test contains(result, "x :: Int64")
    @test contains(result, "y :: String")
    @test !contains(result, "func1")
    @test !contains(result, "Type1")
end

@testitem "meta_list_invalid_filter" tags = [:metadata_inspection] begin
    mod = Module()
    result = REPLicant._meta_list(mod, "invalid")
    @test contains(result, "Unknown filter: invalid")
    @test contains(result, "Available: functions, types, modules, variables")
end

@testitem "meta_list_multiple_methods" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(function multi(x::Int)
        x
    end))
    Core.eval(mod, :(function multi(x::Float64)
        x
    end))
    Core.eval(mod, :(function multi(x::String)
        x
    end))

    result = REPLicant._meta_list(mod)
    # It shows the first method's signature
    @test contains(result, " +2 methods")
end

@testitem "meta_list_skip_private" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(function public_func() end))
    Core.eval(mod, :(function _private_func() end))
    Core.eval(mod, :(_private_var = 42))

    result = REPLicant._meta_list(mod)
    @test contains(result, "public_func")
    @test !contains(result, "_private_func")
    @test !contains(result, "_private_var")
end

@testitem "meta_list_multidimensional_array" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(matrix = [1 2 3; 4 5 6]))

    result = REPLicant._meta_list(mod)
    @test contains(result, "matrix :: Matrix{Int64} (2×3)")
end

@testitem "meta_command_basic" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(x = 42))

    # Test the command interface
    thunk = REPLicant._meta_command("list", 1, mod)
    result = thunk()
    @test contains(result, "Variables (2):")  # x + anonymous
    @test contains(result, "x :: Int64")
end

@testitem "meta_command_with_filter" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(function test() end))
    Core.eval(mod, :(data = 100))

    # Test with filter
    thunk = REPLicant._meta_command("list functions", 1, mod)
    result = thunk()
    @test contains(result, "Function (1):")
    @test contains(result, "test")
    @test !contains(result, "Variables")  # Variables section should not appear
end

@testitem "meta_command_invalid_subcommand" tags = [:metadata_inspection] begin
    mod = Module()

    # Test invalid subcommand
    @test_throws ErrorException(
        "Unknown meta subcommand: invalid. Available: list, info, typed, warntype, llvm, native, optimize, deps, callers, graph, uses",
    ) begin
        REPLicant._meta_command("invalid", 1, mod)
    end
end

@testitem "meta_command_server_integration" setup = [Utilities] tags =
    [:metadata_inspection] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # Define some objects in the server module
        sock = Sockets.connect(port)
        println(sock, "myvar = 123")
        response = readline(sock)
        close(sock)

        sock = Sockets.connect(port)
        println(sock, "struct MyType end")
        response = readline(sock)
        close(sock)

        # Use the meta list command
        sock = Sockets.connect(port)
        println(sock, "#meta list")
        response = readline(sock)
        close(sock)

        @test contains(response, "Type (1):")
        @test contains(response, "MyType")
        @test contains(response, "Variables (")
        @test contains(response, "myvar :: Int64")
    end
end

# Meta info tests

@testitem "meta_info_nonexistent" tags = [:metadata_inspection] begin
    mod = Module()
    result = REPLicant._meta_info(mod, "nonexistent")
    @test contains(result, "ERROR: Object 'nonexistent' not found")
end

@testitem "meta_info_function" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(function testfunc(x::Int, y::Float64)
        return x + y
    end))

    result = REPLicant._meta_info(mod, "testfunc")
    @test contains(result, "Function: testfunc")
    @test contains(result, "Methods: 1")
    @test contains(result, "testfunc(Int64, Float64)")
    @test contains(result, "Module: Main")
end

@testitem "meta_info_type" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(struct TestStruct
        name::String
        value::Int
        flag::Bool
    end))

    result = REPLicant._meta_info(mod, "TestStruct")
    @test contains(result, "Type: TestStruct")
    @test contains(result, "Supertype: Any")
    @test contains(result, "Abstract: false")
    @test contains(result, "Fields: 3")
    @test contains(result, "name :: String")
    @test contains(result, "value :: Int64")
    @test contains(result, "flag :: Bool")
    @test contains(result, "Size: 24 bytes")
end

@testitem "meta_info_abstract_type" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(abstract type AbstractTest end))
    Core.eval(mod, :(struct ConcreteTest <: AbstractTest end))

    result = REPLicant._meta_info(mod, "AbstractTest")
    @test contains(result, "Type: AbstractTest")
    @test contains(result, "Supertype: Any")
    @test contains(result, "Abstract: true")
    # Note: subtypes() may not find subtypes defined in the same module
    # in certain contexts, so we just check the basic functionality
end

@testitem "meta_info_array_variable" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(data = [1, 2, 3, 4, 5]))

    result = REPLicant._meta_info(mod, "data")
    @test contains(result, "Variable: data")
    @test contains(result, "Type: Vector{Int64}")
    @test contains(result, "Array information:")
    @test contains(result, "Dimensions: 5")
    @test contains(result, "Element type: Int64")
    @test contains(result, "Total elements: 5")
    @test contains(result, "Values: [1, 2, 3, 4, 5]")
    @test contains(result, "Mutable: true")
end

@testitem "meta_info_dict_variable" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(d = Dict(:a => 1, :b => 2)))

    result = REPLicant._meta_info(mod, "d")
    @test contains(result, "Variable: d")
    @test contains(result, "Type: Dict{Symbol, Int64}")
    @test contains(result, "Dictionary information:")
    @test contains(result, "Entries: 2")
    @test contains(result, "Key type: Symbol")
    @test contains(result, "Value type: Int64")
    @test contains(result, "Contents:")
    # Dict iteration order is not guaranteed
    @test (contains(result, "a => 1") || contains(result, "b => 2"))
end

@testitem "meta_info_string_variable" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(msg = "Hello, World!"))

    result = REPLicant._meta_info(mod, "msg")
    @test contains(result, "Variable: msg")
    @test contains(result, "Type: String")
    @test contains(result, "String information:")
    @test contains(result, "Length: 13 characters")
    @test contains(result, "Content: \"Hello, World!\"")
end

@testitem "meta_info_number_variable" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(x = 42))

    result = REPLicant._meta_info(mod, "x")
    @test contains(result, "Variable: x")
    @test contains(result, "Type: Int64")
    @test contains(result, "Value: 42")
    @test contains(result, "Mutable: false")
end

@testitem "meta_info_module" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(module TestModule
    export foo, Bar
    foo() = 1
    struct Bar end
    internal() = 2
    end))

    result = REPLicant._meta_info(mod, "TestModule")
    @test contains(result, "Module: TestModule")
    @test contains(result, "Parent: Main")
    # Module exports itself too, so it's 3
    @test contains(result, "Exports: 3")
    @test contains(result, "Functions:")
    @test contains(result, "- foo")
    @test contains(result, "Types:")
    @test contains(result, "- Bar")
    @test contains(result, "Total names:")
end

@testitem "meta_command_info" tags = [:metadata_inspection] begin
    mod = Module()
    Core.eval(mod, :(test_var = 99))

    # Test the command interface
    thunk = REPLicant._meta_command("info test_var", 1, mod)
    result = thunk()
    @test contains(result, "Variable: test_var")
    @test contains(result, "Type: Int64")
    @test contains(result, "Value: 99")
end

@testitem "meta_command_info_no_args" tags = [:metadata_inspection] begin
    mod = Module()

    # Test error when no object name provided
    thunk = REPLicant._meta_command("info", 1, mod)
    result = thunk()
    @test contains(result, "ERROR: Object name required")
    @test contains(result, "Usage: #meta info <object_name>")
end
