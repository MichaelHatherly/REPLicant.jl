@testitem "format_section_header" tags = [:formatting] begin
    # Test level 1 header (main)
    result = REPLicant.format_section_header("Test Header")
    @test contains(result, "Test Header")
    @test contains(result, "=")

    # Test level 2 header
    result = REPLicant.format_section_header("Subsection", 2)
    @test contains(result, "## Subsection")

    # Test level 3 header
    result = REPLicant.format_section_header("Details", 3)
    @test contains(result, "Details:")
end

@testitem "format_key_value" tags = [:formatting] begin
    result = REPLicant.format_key_value("Name", "test_value")
    @test contains(result, "Name: test_value")

    # Test with indentation
    result = REPLicant.format_key_value("Nested", "value", indent_level = 1)
    @test contains(result, "  Nested: value")
end

@testitem "format_list_item" tags = [:formatting] begin
    result = REPLicant.format_list_item("test item")
    @test contains(result, "- test item")

    # Test with custom bullet
    result = REPLicant.format_list_item("warning item", bullet = "⚠")
    @test contains(result, "⚠ warning item")

    # Test with indentation
    result = REPLicant.format_list_item("nested item", indent_level = 1)
    @test contains(result, "  - nested item")
end

@testitem "format_status" tags = [:formatting] begin
    # Test success status
    result = REPLicant.format_status("All good", :success)
    @test contains(result, "✓ All good")

    # Test error status
    result = REPLicant.format_status("Something wrong", :error)
    @test contains(result, "✗ Something wrong")

    # Test warning status
    result = REPLicant.format_status("Be careful", :warning)
    @test contains(result, "⚠ Be careful")

    # Test info status
    result = REPLicant.format_status("Note this", :info)
    @test contains(result, "ℹ Note this")
end

@testitem "format_count" tags = [:formatting] begin
    # Test singular
    result = REPLicant.format_count("Item", 1)
    @test contains(result, "Item (1):")

    # Test plural
    result = REPLicant.format_count("Item", 3)
    @test contains(result, "Items (3):")

    # Test custom plural suffix
    result = REPLicant.format_count("Dependency", 2, plural_suffix = "ies")
    @test contains(result, "Dependencies (2):")
end

@testitem "formatting_consistency_across_commands" setup = [Utilities] tags = [:formatting] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # Create test function
        sock = Sockets.connect(port)
        println(sock, "format_test_func(x::Int) = x * 2")
        response = readline(sock)
        close(sock)

        # Test that all commands use consistent formatting

        # Test list command formatting
        sock = Sockets.connect(port)
        println(sock, "#meta list")
        list_response = readline(sock)
        close(sock)

        @test contains(list_response, "Objects in Main")
        @test contains(list_response, "=")  # Should have section separator
        @test contains(list_response, "##")  # Should have subsection headers

        # Test info command formatting
        sock = Sockets.connect(port)
        println(sock, "#meta info format_test_func")
        info_response = readline(sock)
        close(sock)

        @test contains(info_response, "Function: format_test_func")
        @test contains(info_response, "=")  # Should have section separator
        @test contains(info_response, "##")  # Should have subsection headers

        # Test typed command formatting
        sock = Sockets.connect(port)
        println(sock, "#meta typed format_test_func (Int,)")
        typed_response = readline(sock)
        close(sock)

        @test contains(typed_response, "Type-inferred code for format_test_func")
        @test contains(typed_response, "=")  # Should have section separator
    end
end

@testitem "error_handling_consistency" setup = [Utilities] tags = [:formatting] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # Test error formatting for non-existent function
        sock = Sockets.connect(port)
        println(sock, "#meta info nonexistent_function")
        error_response = readline(sock)
        close(sock)

        @test contains(error_response, "ERROR:")

        # Test error formatting for wrong command
        sock = Sockets.connect(port)
        println(sock, "#meta deps nonexistent_function")
        error_response = readline(sock)
        close(sock)

        @test contains(error_response, "ERROR:")
    end
end
