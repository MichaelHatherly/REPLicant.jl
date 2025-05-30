@testitem "unicode_identifiers" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Greek letters as variables
        sock = Sockets.connect(port)
        println(sock, "α = 2; β = 3; α * β")
        response = readline(sock)
        close(sock)
        @test strip(response) == "6"

        # Mathematical symbols
        sock = Sockets.connect(port)
        println(sock, "∑ = sum; ∑([1, 2, 3])")
        response = readline(sock)
        close(sock)
        @test strip(response) == "6"

        # Complex Unicode identifiers
        sock = Sockets.connect(port)
        println(sock, "变量 = 42; 变量")
        response = readline(sock)
        close(sock)
        @test strip(response) == "42"
    end
end

@testitem "unicode_in_strings" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Basic emoji
        sock = Sockets.connect(port)
        println(sock, "\"Hello 👋 World 🌍\"")
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"Hello 👋 World 🌍\""

        # Complex emoji sequences
        sock = Sockets.connect(port)
        println(sock, "\"👨‍👩‍👧‍👦\"")  # Family emoji with ZWJ sequences
        response = readline(sock)
        close(sock)
        # Julia shows ZWJ sequences as \u200d in string representation
        @test contains(response, "👨") && contains(response, "\\u200d")

        # Mixed scripts
        sock = Sockets.connect(port)
        println(sock, "\"English العربية 中文 日本語\"")
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"English العربية 中文 日本語\""
    end
end

@testitem "unicode_rtl_text" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Arabic RTL text
        sock = Sockets.connect(port)
        println(sock, "\"مرحبا بالعالم\"")
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"مرحبا بالعالم\""

        # Hebrew RTL text
        sock = Sockets.connect(port)
        println(sock, "\"שלום עולם\"")
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"שלום עולם\""

        # Mixed LTR/RTL
        sock = Sockets.connect(port)
        println(sock, "\"Hello مرحبا World\"")
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"Hello مرحبا World\""
    end
end

@testitem "unicode_combining_characters" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Combining diacritics
        sock = Sockets.connect(port)
        println(sock, "\"café\"")  # é as single character
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"café\""

        sock = Sockets.connect(port)
        println(sock, "\"café\"")  # e + combining acute accent
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"café\""

        # Multiple combining characters
        sock = Sockets.connect(port)
        println(sock, "\"ả̂\"")  # a + combining circumflex + combining hook above
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"ả̂\""
    end
end

@testitem "unicode_4byte_sequences" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # 4-byte UTF-8 sequences (outside BMP)
        sock = Sockets.connect(port)
        println(sock, "\"𝕳𝖊𝖑𝖑𝖔\"")  # Mathematical bold text
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"𝕳𝖊𝖑𝖑𝖔\""

        # Ancient scripts
        sock = Sockets.connect(port)
        println(sock, "\"𐌰𐌱𐌲𐌳\"")  # Gothic alphabet
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"𐌰𐌱𐌲𐌳\""

        # Musical symbols
        sock = Sockets.connect(port)
        println(sock, "\"𝄞𝄢𝄪\"")
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"𝄞𝄢𝄪\""
    end
end

@testitem "unicode_in_errors" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Error with Unicode variable name
        sock = Sockets.connect(port)
        println(sock, "未定义的变量")
        response = readline(sock)
        close(sock)
        @test startswith(response, "ERROR:")
        @test contains(response, "UndefVarError")
        @test contains(response, "未定义的变量")

        # Error in Unicode string operations
        sock = Sockets.connect(port)
        println(sock, "\"Hello\" * 123")
        response = readline(sock)
        close(sock)
        @test startswith(response, "ERROR:")
        @test contains(response, "MethodError")
    end
end

@testitem "unicode_length_operations" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # String length with Unicode
        sock = Sockets.connect(port)
        println(sock, "length(\"Hello 👋\")")
        response = readline(sock)
        close(sock)
        @test strip(response) == "7"  # 6 chars + 1 emoji

        # Grapheme length - need to import Unicode
        sock = Sockets.connect(port)
        println(sock, "using Unicode; length(collect(graphemes(\"👨‍👩‍👧‍👦\")))")
        response = readline(sock)
        close(sock)
        @test strip(response) == "1"  # Single grapheme cluster

        # Codeunit length
        sock = Sockets.connect(port)
        println(sock, "ncodeunits(\"🌍\")")
        response = readline(sock)
        close(sock)
        @test strip(response) == "4"  # 4-byte UTF-8 sequence
    end
end

@testitem "unicode_edge_cases" tags = [:protocol, :unicode] setup = [Utilities] begin
    using REPLicant
    using Sockets

    Utilities.withserver() do server, mod, port
        # Zero-width characters
        sock = Sockets.connect(port)
        println(sock, "\"Hello\\u200BWorld\"")  # Zero-width space
        response = readline(sock)
        close(sock)
        @test strip(response) == "\"Hello\\u200bWorld\""

        # Directional markers
        sock = Sockets.connect(port)
        println(sock, "\"\\u202Eright-to-left\\u202C\"")
        response = readline(sock)
        close(sock)
        # Check for the escape sequence in the response
        @test contains(response, "\\u202e")

        # Surrogate pairs (should error in Julia)
        sock = Sockets.connect(port)
        println(sock, "\"\\uD800\"")  # Invalid surrogate
        response = readline(sock)
        close(sock)
        @test startswith(response, "ERROR:") || contains(response, "\\ud800")
    end
end
