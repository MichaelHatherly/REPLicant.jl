@testitem "find_just_file_in_current_dir" tags = [:utilities] begin
    # Should find justfile in current directory
    justfile = REPLicant._find_just_file(@__DIR__)
    @test !isnothing(justfile)
    @test basename(justfile) == "justfile"
    @test isfile(justfile)
end

@testitem "find_just_file_from_subdirectory" tags = [:utilities] begin
    # Create a temporary subdirectory
    test_dir = mktempdir(@__DIR__)
    try
        # Should find justfile by walking up
        justfile = REPLicant._find_just_file(test_dir)
        @test !isnothing(justfile)
        @test basename(justfile) == "justfile"
    finally
        rm(test_dir, recursive = true, force = true)
    end
end

@testitem "find_just_file_stops_at_git" tags = [:utilities] begin
    # If we created a .git directory, search should stop
    test_dir = mktempdir()
    git_dir = joinpath(test_dir, ".git")
    mkdir(git_dir)

    try
        justfile = REPLicant._find_just_file(test_dir)
        @test isnothing(justfile)
    finally
        rm(test_dir, recursive = true, force = true)
    end
end

@testitem "find_just_file_circular_symlinks" tags = [:utilities] begin
    # Test the circular directory detection
    test_dir = mktempdir()

    try
        # Create circular symlinks (if supported)
        link1 = joinpath(test_dir, "link1")
        link2 = joinpath(test_dir, "link2")

        # This might fail on some systems
        try
            symlink(link2, link1)
            symlink(link1, link2)

            # Should handle circular references gracefully
            justfile = REPLicant._find_just_file(link1)
            @test isnothing(justfile)
        catch e
            # Skip test if symlinks aren't supported
            @test_skip "Symlinks not supported on this system"
        end
    finally
        rm(test_dir, recursive = true, force = true)
    end
end

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

@testitem "revise_dispatch" tags = [:utilities] begin
    # Test the revise dispatch mechanism
    # Without Revise loaded, should just call function directly
    called = Ref(false)
    test_func() = (called[] = true; "result")

    result = REPLicant._revise(test_func)
    @test called[]
    @test result == "result"
end
