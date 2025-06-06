@testitem "include_file_command" tags = [:custom_commands, :protocol] setup = [Utilities] begin
    using Sockets

    Utilities.withserver() do server, mod, port
        # Create a test file to include
        write(
            "test_include.jl",
            """
            test_var = "Hello from included file"
            function test_func()
                return 42
            end
            """,
        )
        sock = Sockets.connect(port)

        # Test successful file inclusion
        println(sock, "#include-file test_include.jl")
        response = readline(sock)
        @test contains(response, "test_func")
        close(sock)

        # Verify the file was included by checking if symbols are defined
        sock = connect(port)
        println(sock, "test_var")
        response = readline(sock)
        @test strip(response) == "\"Hello from included file\""
        close(sock)

        sock = connect(port)
        println(sock, "test_func()")
        response = readline(sock)
        @test strip(response) == "42"
        close(sock)

        # Test file not found error
        sock = connect(port)
        println(sock, "#include-file nonexistent.jl")
        response = readline(sock)
        @test startswith(response, "ERROR:")
        @test contains(response, "File not found")
        close(sock)

        # Test relative paths
        mkdir("subdir")
        write("subdir/nested.jl", "nested_var = 999")

        sock = connect(port)
        println(sock, "#include-file subdir/nested.jl")
        response = readline(sock)
        close(sock)

        sock = connect(port)
        println(sock, "nested_var")
        response = readline(sock)
        @test strip(response) == "999"
        close(sock)
    end
end

@testitem "custom_command_registration" tags = [:custom_commands, :server_lifecycle] setup =
    [Utilities] begin
    using Sockets

    # Define custom commands
    commands = Dict{String,Function}(
        "echo" => (code, id, mod) -> () -> "Echo: $code",
        "reverse" => (code, id, mod) -> () -> reverse(code),
        "eval-twice" =>
            (code, id, mod) -> begin
                () -> begin
                    result1 = include_string(mod, code, "REPL[$id]-1")
                    result2 = include_string(mod, code, "REPL[$id]-2")
                    return (result1, result2)
                end
            end,
    )

    Utilities.withserver(; commands) do server, mod, port
        # Test echo command
        sock = connect(port)
        println(sock, "#echo Hello World")
        response = readline(sock)
        @test strip(response) == "\"Echo: Hello World\""
        close(sock)

        # Test reverse command
        sock = connect(port)
        println(sock, "#reverse Julia")
        response = readline(sock)
        @test strip(response) == "\"ailuJ\""
        close(sock)

        # Test eval-twice command
        sock = connect(port)
        println(sock, "#eval-twice rand()")
        response = readline(sock)
        # Should return a tuple of two different random numbers
        @test contains(response, "(") && contains(response, ",")
        close(sock)

        # Test that built-in commands still work
        sock = connect(port)
        println(sock, "1 + 1")
        response = readline(sock)
        @test strip(response) == "2"
        close(sock)
    end
end

@testitem "command_error_handling" tags = [:custom_commands, :error_handling] setup =
    [Utilities] begin
    using Sockets

    Utilities.withserver() do server, mod, port
        # Test unknown command
        sock = connect(port)
        println(sock, "#unknown-command arg1 arg2")
        response = readline(sock)
        @test startswith(response, "ERROR:")
        @test contains(response, "Unknown command: unknown-command")
        close(sock)

        # Test malformed command (should be treated as regular code)
        sock = connect(port)
        println(sock, "]")
        response = readline(sock)
        # This should evaluate as a syntax error
        @test startswith(response, "ERROR:")
        close(sock)

        # Test command with empty name
        sock = connect(port)
        println(sock, "# some code")
        response = readline(sock)
        # This should evaluate as a comment (nothing)
        @test strip(response) == "nothing"
        close(sock)
    end
end

@testitem "command_state_modification" tags = [:custom_commands, :state_persistence] setup =
    [Utilities] begin
    using Sockets

    # Command that modifies module state
    commands = Dict{String,Function}(
        "set-var" =>
            (code, id, mod) -> begin
                var_name, value = split(code, "=")
                () -> Core.eval(mod, Meta.parse("$var_name = $value"))
            end,
        "get-var" => (code, id, mod) -> begin
            () -> Core.eval(mod, Symbol(strip(code)))
        end,
    )

    Utilities.withserver(; commands) do server, mod, port
        # Set a variable using custom command
        sock = connect(port)
        println(sock, "#set-var test_state=100")
        response = readline(sock)
        @test strip(response) == "100"
        close(sock)

        # Verify the variable persists
        sock = connect(port)
        println(sock, "#get-var test_state")
        response = readline(sock)
        @test strip(response) == "100"
        close(sock)

        # Also verify with regular evaluation
        sock = connect(port)
        println(sock, "test_state * 2")
        response = readline(sock)
        @test strip(response) == "200"
        close(sock)
    end
end

@testitem "command_unicode_support" tags = [:custom_commands, :unicode] setup = [Utilities] begin
    using Sockets

    commands = Dict{String,Function}(
        "unicode-length" => (code, id, mod) -> () -> length(code),
        "unicode-reverse" => (code, id, mod) -> () -> join(reverse(collect(code))),
    )

    Utilities.withserver(; commands) do server, mod, port
        # Test Unicode in command arguments
        sock = connect(port)
        println(sock, "#unicode-length 你好世界")
        response = readline(sock)
        @test strip(response) == "4"
        close(sock)

        sock = connect(port)
        println(sock, "#unicode-reverse 🚀Julia🎉")
        response = readline(sock)
        @test strip(response) == "\"🎉ailuJ🚀\""
        close(sock)
    end
end

@testitem "_eval_code_with_commands" tags = [:custom_commands, :code_evaluation] begin
    import Logging
    import Test

    # Direct testing of _eval_code with custom commands
    mktempdir() do dir
        cd(dir) do
            # Create justfile in temp directory
            write("justfile", "# Test justfile")

            # Create test file
            write("test_include.jl", "included_var = 123")

            mod = Module()

            # Test built-in include-file command
            result = REPLicant._eval_code("#include-file test_include.jl", 1, mod)
            @test contains(result, "123")
            @test Core.eval(mod, :included_var) == 123

            # Test custom command
            commands = Dict{String,Function}(
                "double" => (code, id, mod) -> () -> 2 * parse(Int, code),
            )

            result = REPLicant._eval_code("#double 21", 1, mod, commands)
            @test strip(result) == "42"

            # Test unknown command
            logger = Test.TestLogger()
            Logging.with_logger(logger) do
                result = REPLicant._eval_code("#nonexistent test", 1, mod, commands)
                @test startswith(result, "ERROR:")
                @test contains(result, "Unknown command: nonexistent")
            end
            @test length(logger.logs) == 1

            # Test regular code still works
            result = REPLicant._eval_code("sqrt(16)", 1, mod, commands)
            @test strip(result) == "4.0"
        end
    end
end
