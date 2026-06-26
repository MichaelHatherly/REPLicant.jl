@testitem "routing_display_declines_without_target" tags = [:output_routing] begin
    import REPLicant

    REPLicant._install_routing!()
    # With no capture target bound, `RouterDisplay` declines via a `MethodError`
    # so the global display stack falls through to the REPL's own display.
    @test_throws MethodError display(REPLicant.RouterDisplay(), 3)
end

@testitem "routing_captures_when_bound" tags = [:output_routing] begin
    import REPLicant

    REPLicant._install_routing!()
    target = REPLicant.LockedIO(IOBuffer())
    REPLicant.with(REPLicant.CAPTURE_TARGET => target) do
        # `println` routes through the installed stdout router; `display` through
        # the display router. Both land in the bound target.
        println("printed")
        display(REPLicant.RouterDisplay(), 42)
    end
    out = String(take!(target.buffer))
    @test contains(out, "printed")
    @test contains(out, "42")
end

@testitem "routing_inherits_child_tasks" tags = [:output_routing] begin
    import REPLicant

    # The `ScopedValue` binding inherits into child tasks on 1.11+. The vendored
    # 1.10 value is same-task, so child output falls through there; gate the assertion.
    if isdefined(Base, :ScopedValues)
        REPLicant._install_routing!()
        target = REPLicant.LockedIO(IOBuffer())
        REPLicant.with(REPLicant.CAPTURE_TARGET => target) do
            wait(Threads.@spawn println("from_child"))
        end
        @test contains(String(take!(target.buffer)), "from_child")
    else
        @test true skip = true
    end
end
