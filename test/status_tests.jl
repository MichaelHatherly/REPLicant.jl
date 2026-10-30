# What REPLicant puts in the footer: a status row read off the running server, and a
# tail of the activity log. Both are rendered at paint time against the width the
# terminal has right then, so they are functions of that width here too.

@testitem "status_duration_formatting" tags = [:footer] begin
    import REPLicant

    @test REPLicant._duration(0) == "0s"
    @test REPLicant._duration(59.6) == "59s"
    @test REPLicant._duration(60) == "1m"
    @test REPLicant._duration(90) == "1m"
    @test REPLicant._duration(3599) == "59m"
    @test REPLicant._duration(3600) == "1h00m"
    @test REPLicant._duration(3600 + 125 * 60) == "3h05m"
end

@testitem "status_row_without_a_server" tags = [:footer] begin
    import Dates
    import REPLicant

    row = REPLicant._render_status(nothing, Dates.now(), 80)
    @test occursin("REPLicant", row)
    @test occursin("no server", row)
end

@testitem "footer_stays_on_the_sessions_server" tags = [:footer] setup = [Utilities] begin
    import REPLicant

    # Servers started later in the process, as tests start them, must not take the
    # row over or blank it when they close.
    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            _, port = start(; save = true)
            other, _ = start()
            @test occursin(":$port", REPLicant._status_row(120))
            Utilities.wait_closed(other)
            @test occursin(":$port", REPLicant._status_row(120))
        end
        @test occursin("no server", REPLicant._status_row(120))
    end
end

@testitem "footer_reports_an_unsaved_server" tags = [:footer] setup = [Utilities] begin
    import REPLicant

    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            _, port = start()
            @test occursin(":$port", REPLicant._status_row(120))
        end
    end
end

@testitem "status_row_reports_the_running_server" tags = [:footer] setup = [Utilities] begin
    import Dates
    import REPLicant

    Utilities.withserver() do server, mod, port
        now = Dates.now()
        idle = REPLicant._render_status(server, now, 120)
        @test occursin(":$port", idle)
        @test occursin(basename(server.project), idle)
        @test occursin("idle", idle)
        @test occursin("up 0s", idle)

        # A label identifies which of several servers in a project this is.
        server.name = "demo"
        @test occursin("demo", REPLicant._render_status(server, now, 120))

        # The elapsed time is what tells a long evaluation from a wedged one, so it
        # is read at render time rather than frozen when the evaluation started.
        server.busy_since = now - Dates.Second(90)
        busy = REPLicant._render_status(server, now, 120)
        @test occursin("busy 1m", busy)
        @test !occursin("idle", busy)
    end
end

@testitem "status_row_gives_up_context_before_state" tags = [:footer] setup = [Utilities] begin
    import Dates
    import REPLicant

    Utilities.withserver() do server, mod, port
        now = Dates.now()
        wide = REPLicant._render_status(server, now, 120)
        @test occursin(basename(server.project), wide)

        # Too narrow to hold everything: the project and the uptime go, the port and
        # the state stay, and what is left fits without the terminal truncating it.
        narrow = REPLicant._render_status(server, now, 14)
        @test occursin(":$port", narrow)
        @test occursin("idle", narrow)
        @test !occursin(basename(server.project), narrow)
        @test REPLicant.Footers.display_width(narrow) <= 14
    end
end

@testitem "status_row_shows_the_running_code" tags = [:footer] setup = [Utilities] begin
    import Dates
    import REPLicant

    Utilities.withserver() do server, mod, port
        # The worker records what it is running for as long as it runs it.
        running = @async Utilities.request(port, "sleep(1); :slept")
        @test timedwait(() -> !isnothing(server.busy_since), 5.0) === :ok
        @test server.busy_code == "sleep(1); :slept"
        wait(running)
        # The reply reaches the client before the worker clears its busy state, so
        # wait for that, or it lands on the state set by hand below.
        @test timedwait(() -> isnothing(server.busy_since), 5.0) === :ok

        now = Dates.now()
        server.busy_since = now - Dates.Second(2)
        server.busy_code = "sleep(6); :slept"
        busy = REPLicant._render_status(server, now, 120)
        @test occursin("busy 2s", busy)
        @test occursin("sleep(6); :slept", busy)

        # A multi-line request is shown by its first line, with the rest marked.
        server.busy_code = "function f(x)\n    x + 1\nend"
        multi = REPLicant._render_status(server, now, 120)
        @test !occursin('\n', multi)
        @test occursin("function f(x) …", multi)

        # The code belongs to the evaluation, so an idle row never shows it.
        server.busy_since = nothing
        @test !occursin("function f(x)", REPLicant._render_status(server, now, 120))
    end
end

@testitem "status_row_cuts_the_code_first" tags = [:footer] setup = [Utilities] begin
    import Dates
    import REPLicant

    Utilities.withserver() do server, mod, port
        now = Dates.now()
        server.busy_since = now
        server.busy_code = repeat("x", 200)

        # Long code is cut to the columns left over, and every field survives.
        wide = REPLicant._render_status(server, now, 80)
        @test REPLicant.Footers.display_width(wide) <= 80
        @test occursin(basename(server.project), wide)
        @test occursin("busy 0s", wide)
        @test occursin("xxx", wide)

        # With no columns left over, the code goes before any field does.
        narrow = REPLicant._render_status(server, now, 14)
        @test !occursin("x", narrow)
        @test occursin(":$port", narrow)
        @test occursin("busy", narrow)
    end
end

@testitem "footer_repaints_once_the_server_is_idle" tags = [:footer] setup = [Utilities] begin
    import REPLicant

    footer = REPLicant.Footers.FOOTER
    # A private wake event, so a live footer in the session running the tests does
    # not take the repaint requests this item is counting.
    live_wake = footer.wake
    wake = footer.wake = Base.Event(true)
    try
        Utilities.withserver() do server, mod, port
            # Stand in for the footer's dispatch task: on every repaint request,
            # note what the status row would read.
            seen = Any[]
            done = Ref(false)
            watcher = @async while true
                wait(wake)
                done[] && break
                push!(seen, server.busy_since)
            end

            @test Utilities.request(port, "sleep(0.2); :slept") == ":slept"
            @test timedwait(() -> isnothing(server.busy_since), 5.0) === :ok
            yield()
            done[] = true
            notify(wake)
            wait(watcher)

            # Without a repaint after the worker goes idle, the row keeps saying
            # busy until the next idle repaint, up to 30s later.
            @test isnothing(last(seen))
        end
    finally
        footer.wake = live_wake
    end
end
