@testitem "show_object_display" tags = [:utilities] begin
    # Test the display function for various types
    buffer = IOBuffer()
    mod = Main

    # Simple value
    result = (value = 42, error = false, output = "")
    REPLicant._show_object(buffer, result, mod)
    @test String(take!(buffer)) == "42"

    # Array
    result = (value = [1, 2, 3], error = false, output = "")
    REPLicant._show_object(buffer, result, mod)
    output = String(take!(buffer))
    @test contains(output, "3-element Vector{Int64}")

    # Custom type
    result = (value = Dict(:a => 1), error = false, output = "")
    REPLicant._show_object(buffer, result, mod)
    output = String(take!(buffer))
    @test contains(output, "Dict{Symbol, Int64}")
end

@testitem "error_message_formatting" tags = [:utilities] begin
    # Test error message formatting
    buffer = IOBuffer()

    # Create a mock error result
    try
        error("Test error")
    catch e
        bt = catch_backtrace()
        result = (value = (error = e,), backtrace = bt, error = true)
        REPLicant._error_message(buffer, result, 1)

        output = String(take!(buffer))
        @test startswith(output, "ERROR:")
        @test contains(output, "Test error")
    end
end

@testitem "busy_depth_counter" tags = [:utilities] begin
    # Busy state is a depth counter: nested signals stack, and only the matching
    # number of decrements clears it. Restored to idle at the end.
    @test !REPLicant._is_busy()
    REPLicant._notify_busy(1)
    @test REPLicant._is_busy()
    REPLicant._notify_busy(1)
    @test REPLicant._is_busy()
    REPLicant._notify_busy(-1)
    @test REPLicant._is_busy()
    REPLicant._notify_busy(-1)
    @test !REPLicant._is_busy()
end

@testitem "busy_hook_safe_without_repl" tags = [:utilities] begin
    import REPL  # loads the REPL extension, which overrides __notify_busy
    # The server starts before any interactive REPL exists, so the hook must be a
    # safe no-op when `Base.active_repl` is unset while the counter still tracks.
    @test !REPLicant._is_busy()
    REPLicant._notify_busy(1)
    @test REPLicant._is_busy()
    REPLicant._notify_busy(-1)
    @test !REPLicant._is_busy()
end

@testitem "revise_dispatch" tags = [:utilities] begin
    # Test the revise dispatch mechanism
    # Without Revise loaded, should just call function directly
    called = Ref(false)
    test_func() = (called[] = true; "result")

    result = REPLicant._revise(test_func)
    @test called[]
    @test result == "result"
end
