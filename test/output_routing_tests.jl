@testitem "routing_display_declines_without_target" tags = [:output_routing] setup = [Utilities] begin
    import REPLicant

    REPLicant._install_routing!()
    # With no capture target bound, `RouterDisplay` declines via a `MethodError`
    # so the global display stack falls through to the REPL's own display.
    Utilities.outside_capture() do
        @test_throws MethodError display(REPLicant.RouterDisplay(), 3)
    end
end

@testitem "routing_captures_when_bound" tags = [:output_routing] begin
    import REPLicant

    REPLicant._install_routing!()
    target = IOBuffer()
    REPLicant.with(REPLicant.CAPTURE_TARGET => target) do
        # `println` routes through the installed stdout router; `display` through
        # the display router. Both land in the bound target.
        println("printed")
        display(REPLicant.RouterDisplay(), 42)
    end
    out = String(take!(target))
    @test contains(out, "printed")
    @test contains(out, "42")
end

@testitem "routing_inherits_child_tasks" tags = [:output_routing] begin
    import REPLicant

    # The `ScopedValue` binding inherits into child tasks on 1.11+. The vendored
    # 1.10 value is same-task, so child output falls through there; gate the assertion.
    if isdefined(Base, :ScopedValues)
        REPLicant._install_routing!()
        target = IOBuffer()
        REPLicant.with(REPLicant.CAPTURE_TARGET => target) do
            wait(Threads.@spawn println("from_child"))
        end
        @test contains(String(take!(target)), "from_child")
    else
        @test true skip = true
    end
end

@testitem "closing_one_server_keeps_routing_for_the_rest" tags = [:output_routing] setup = [Utilities] begin
    import REPLicant

    # Routing is installed once per process, so a test server closing inside a warm
    # session must leave it to the session's own server.
    Utilities.withproject() do start, _
        closing, _ = start()
        start()
        Utilities.wait_closed(closing)
        @test stdout isa REPLicant.Router
    end
end

@testitem "routing_change_inside_capture_keeps_fds_on_capture" tags = [:output_routing] begin
    import REPLicant

    # Rebinding the global streams dups their fds onto fd 1/2, which inside a
    # capture belong to it.
    outer = REPLicant._capture() do
        REPLicant._uninstall_routing!()
        REPLicant._install_routing!()
        run(`echo after-reroute`)
        nothing
    end
    @test contains(outer.output, "after-reroute")
end

@testitem "uninstall_routing_pops_its_own_display" tags = [:output_routing] begin
    import REPLicant

    # The REPL pushes its display after a startup.jl server has installed routing.
    REPLicant._uninstall_routing!()
    REPLicant._install_routing!()
    repl_display = TextDisplay(IOBuffer())
    pushdisplay(repl_display)
    try
        REPLicant._uninstall_routing!()
        @test Base.Multimedia.displays[end] === repl_display
        @test !any(d -> d isa REPLicant.RouterDisplay, Base.Multimedia.displays)
    finally
        filter!(d -> d !== repl_display, Base.Multimedia.displays)
        # Hand routing back, as a warm session's own server still relies on it.
        REPLicant._install_routing!()
    end
end
