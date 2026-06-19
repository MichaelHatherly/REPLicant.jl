@testitem "unicode_identifiers" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "α = 2; β = 3; α * β") == "6"
        @test Utilities.request(port, "∑ = sum; ∑([1, 2, 3])") == "6"
        @test Utilities.request(port, "变量 = 42; 变量") == "42"
    end
end

@testitem "unicode_in_strings" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "\"Hello 👋 World 🌍\"") == "\"Hello 👋 World 🌍\""

        # Family emoji with ZWJ sequences; Julia shows ZWJ as ‍.
        response = Utilities.request(port, "\"👨‍👩‍👧‍👦\"")
        @test contains(response, "👨") && contains(response, "\\u200d")

        @test Utilities.request(port, "\"English العربية 中文 日本語\"") ==
            "\"English العربية 中文 日本語\""
    end
end

@testitem "unicode_rtl_text" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "\"مرحبا بالعالم\"") == "\"مرحبا بالعالم\""
        @test Utilities.request(port, "\"שלום עולם\"") == "\"שלום עולם\""
        @test Utilities.request(port, "\"Hello مرحبا World\"") == "\"Hello مرحبا World\""
    end
end

@testitem "unicode_combining_characters" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "\"café\"") == "\"café\""
        @test Utilities.request(port, "\"café\"") == "\"café\""
        @test Utilities.request(port, "\"ả̂\"") == "\"ả̂\""
    end
end

@testitem "unicode_4byte_sequences" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "\"𝕳𝖊𝖑𝖑𝖔\"") == "\"𝕳𝖊𝖑𝖑𝖔\""
        @test Utilities.request(port, "\"𐌰𐌱𐌲𐌳\"") == "\"𐌰𐌱𐌲𐌳\""
        @test Utilities.request(port, "\"𝄞𝄢𝄪\"") == "\"𝄞𝄢𝄪\""
    end
end

@testitem "unicode_in_errors" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        response = Utilities.request(port, "未定义的变量")
        @test startswith(response, "ERROR:")
        @test contains(response, "UndefVarError")
        @test contains(response, "未定义的变量")

        response = Utilities.request(port, "\"Hello\" * 123")
        @test startswith(response, "ERROR:")
        @test contains(response, "MethodError")
    end
end

@testitem "unicode_length_operations" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "length(\"Hello 👋\")") == "7"
        @test Utilities.request(
            port,
            "using Unicode; length(collect(graphemes(\"👨‍👩‍👧‍👦\")))",
        ) == "1"
        @test Utilities.request(port, "ncodeunits(\"🌍\")") == "4"
    end
end

@testitem "unicode_edge_cases" tags = [:protocol, :unicode] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        @test Utilities.request(port, "\"Hello\\u200BWorld\"") == "\"Hello\\u200bWorld\""

        response = Utilities.request(port, "\"\\u202Eright-to-left\\u202C\"")
        @test contains(response, "\\u202e")

        response = Utilities.request(port, "\"\\uD800\"")
        @test startswith(response, "ERROR:") || contains(response, "\\ud800")
    end
end
