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
    end
end
