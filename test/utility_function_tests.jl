@testitem "show_object_display" tags = [:utilities] begin
    # Test the display function for various types
    buffer = IOBuffer()
    mod = Main

    # Simple value
    REPLicant._show_object(buffer, 42, mod)
    @test String(take!(buffer)) == "42"

    # Array
    REPLicant._show_object(buffer, [1, 2, 3], mod)
    output = String(take!(buffer))
    @test contains(output, "3-element Vector{Int64}")

    # Custom type
    REPLicant._show_object(buffer, Dict(:a => 1), mod)
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

@testitem "busy_follows_the_session_server" tags = [:utilities] setup = [Utilities] begin
    import Dates

    # The title and footer report the session's server. A test server evaluating
    # must not mark the session busy.
    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            session, _ = start(; save = true)
            other, _ = start()
            REPLicant._set_busy!(other, Dates.now(), "work()")
            @test !REPLicant._is_busy()
            REPLicant._set_busy!(session, Dates.now(), "work()")
            @test REPLicant._is_busy()
            REPLicant._set_busy!(session, nothing)
            REPLicant._set_busy!(other, nothing)
            @test !REPLicant._is_busy()
        end
    end
end

@testitem "busy_hook_safe_without_repl" tags = [:utilities] setup = [Utilities] begin
    import Dates
    import REPL  # loads the REPL extension, which overrides __notify_busy

    # The server starts before any interactive REPL exists, so the hook must be a
    # safe no-op when `Base.active_repl` is unset.
    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            session, _ = start(; save = true)
            REPLicant._set_busy!(session, Dates.now(), "work()")
            @test REPLicant._is_busy()
            REPLicant._set_busy!(session, nothing)
            @test !REPLicant._is_busy()
        end
    end
end

@testitem "busy_title_is_one_write" tags = [:utilities] begin
    import REPL

    # Records each write it is handed, as the terminal would receive them.
    struct WriteLog <: IO
        writes::Vector{String}
    end
    Base.unsafe_write(io::WriteLog, p::Ptr{UInt8}, n::UInt) =
        (push!(io.writes, unsafe_string(p, n)); n)
    Base.write(io::WriteLog, b::UInt8) = (push!(io.writes, String([b])); 1)

    ext = Base.get_extension(REPLicant, :REPLicantREPLExt)
    log = WriteLog(String[])
    ext._write_title(log, true)
    ext._write_title(log, false)
    # The footer repaints from another task. A title split across writes lets a
    # repaint land inside the escape sequence, and the title prints as text.
    @test log.writes == ["\e]2;● julia — remote eval\a", "\e]2;julia\a"]
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
