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

@testitem "activity_tail_rows" tags = [:footer] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()
    @test REPLicant._render_activity(REPLicant._recent_activity(3), 80) == ""

    REPLicant._record_activity(:socket, "1 + 1", "2", false)
    REPLicant._record_activity(:socket, "sqrt(-1)", "ERROR: DomainError", true)
    REPLicant._record_repl_input("x = 1")

    rows = split(REPLicant._render_activity(REPLicant._recent_activity(3), 80), '\n')
    @test length(rows) == 3
    # Oldest first, so the newest sits closest to the prompt.
    @test occursin("1 + 1", rows[1])
    @test occursin("sqrt(-1)", rows[2])
    @test occursin("x = 1", rows[3])
    # Each row says where the entry came from and which sequence number it has, so
    # it lines up with what a `log` request renders.
    @test occursin("#1", rows[1])
    @test occursin("socket", rows[1])
    @test occursin("repl", rows[3])

    # Output is not shown: the tail is a glance at what ran, not a transcript.
    @test !occursin("DomainError", rows[2])

    # Only the last few, and only ever the last few.
    @test length(split(REPLicant._render_activity(REPLicant._recent_activity(2), 80), '\n')) == 2
end

@testitem "activity_tail_aligns_its_columns" tags = [:footer] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()
    # Start below a digit boundary, so the sequence numbers differ in width.
    REPLicant.ACTIVITY_SEQ[] = 8
    REPLicant._record_activity(:socket, "a = 1", "1", false)
    REPLicant._record_repl_input("b = 2")

    rows = split(REPLicant._render_activity(REPLicant._recent_activity(2), 80), '\n')
    plain = [replace(row, r"\e\[[0-9;]*m" => "") for row in rows]
    @test startswith(plain[1], "#9 ")
    @test startswith(plain[2], "#10 ")
    # Sequence, source, and time are padded, so the code starts in one column.
    @test findfirst("a = 1", plain[1]) == findfirst("b = 2", plain[2])
end

@testitem "activity_tail_takes_one_row_per_entry" tags = [:footer] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()
    REPLicant._record_activity(:socket, "function f(x)\n    x + 1\nend", "f (generic function with 1 method)", false)

    row = REPLicant._render_activity(REPLicant._recent_activity(1), 80)
    # A multi-line input is one row with the rest of it accounted for, rather than
    # three rows of footer for one entry.
    @test !occursin('\n', row)
    @test occursin("function f(x)", row)
    @test occursin("…", row)
end

@testitem "recent_activity_includes_the_open_entry" tags = [:footer] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()
    REPLicant._record_activity(:socket, "a = 1", "1", false)
    # The human's line stays open while its output streams in, so a tail that waited
    # for the next prompt would always be a line behind.
    REPLicant._record_repl_input("b = 2")

    entries = REPLicant._recent_activity(5)
    @test [entry.code for entry in entries] == ["a = 1", "b = 2"]
    @test [entry.source for entry in entries] == [:socket, :repl]

    # Asking for more than there is gives what there is.
    @test length(REPLicant._recent_activity(100)) == 2
    @test isempty(REPLicant._recent_activity(0))
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
