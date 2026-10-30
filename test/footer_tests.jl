# The footer reserves the bottom rows of the terminal and repaints them while the
# REPL scrolls underneath. `paint` is pure, taking the rows the last repaint left on
# screen and returning the bytes that move them to their new size and contents, so
# the row arithmetic is checked here as byte strings rather than against a terminal.

@testmodule FooterHarness begin
    import REPLicant

    const F = REPLicant.Footers

    # Sections as the footer stores them, without going through a live footer.
    sections(pairs...) = Pair{Any, F.Section}[l => F.Section(v, r) for (l, v, r) in pairs]
    flines(secs, h, w) = F.footer_lines(secs, h, w)

    # `displaysize` on an IOContext is settable, so a resize is a new context over
    # the same buffer.
    function harness(height, width)
        buf = IOBuffer()
        footer = F.Footer(IOContext(buf, :displaysize => (height, width)))
        footer.enabled = true
        return footer, buf
    end

    resize(footer, height, width) =
        footer.io = IOContext(footer.io.io, :displaysize => (height, width))
    written(buf) = String(take!(buf))
end

@testitem "footer_fit_and_width" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F

    @test F.fit("hello", 3) == "hel"
    @test F.fit("hello", 10) == "hello"
    @test F.fit("", 10) == ""
    @test F.fit("hello", 0) == ""

    # Escape sequences occupy no display width and survive truncation.
    @test F.fit("\e[31mhello\e[0m", 3) == "\e[31mhel"
    @test F.fit("\e[31mab\e[0m", 10) == "\e[31mab\e[0m"

    # Wide characters count as the width the terminal gives them.
    @test F.fit("日本語", 4) == "日本"

    @test F.display_width("hello") == 5
    @test F.display_width("\e[31mhello\e[0m") == 5
    @test F.display_width("日本語") == 6
    @test F.display_width("") == 0

    # A control character would move the cursor, so each one shows as a space.
    @test F.fit("a\tb", 10) == "a b"
    @test F.display_width("a\tb") == 3
    @test F.fit("abc\r\nxyz", 10) == "abc  xyz"
    @test F.fit("a\tb", 2) == "a "
end

@testitem "footer_lines_from_sections" tags = [:footer] setup = [FooterHarness] begin
    flines, sections = FooterHarness.flines, FooterHarness.sections

    @test flines(sections(), 24, 80) == String[]
    @test flines(sections((:a, "one", nothing)), 24, 80) == ["one"]
    @test flines(sections((:a, "one\ntwo", nothing)), 24, 80) == ["one", "two"]
    @test flines(sections((:a, "one\n", nothing)), 24, 80) == ["one"]
    @test flines(sections((:a, "", nothing)), 24, 80) == String[]
    @test flines(sections((:a, "one", nothing), (:b, "two\nthree", nothing)), 24, 80) ==
        ["one", "two", "three"]
end

@testitem "footer_section_rendering" tags = [:footer] setup = [FooterHarness] begin
    F, flines, sections = FooterHarness.F, FooterHarness.flines, FooterHarness.sections

    # A function is handed the width, so it is redrawn at whatever size the
    # terminal happens to be when the footer paints.
    @test flines(sections((:r, w -> "-"^w, nothing)), 24, 5) == ["-----"]
    @test flines(sections((:r, w -> "-"^w, nothing)), 24, 9) == ["---------"]

    # Anything else shows itself at the size the footer has. A 20x20 matrix does
    # not fit in six rows, and knows how to say so itself. It may come back shorter
    # than the cap, since show reserves rows of its own.
    lines = flines(sections((:m, rand(20, 20), 6)), 24, 60)
    @test 1 <= length(lines) <= 6
    @test occursin("20×20 Matrix", first(lines))
    @test any(line -> occursin("⋮", line), lines)

    # Wider is not taller: the cap binds, not the content.
    @test length(flines(sections((:m, rand(20, 20), 2)), 24, 60)) <= 2
    @test flines(sections((:m, rand(3, 3), 0)), 24, 60) == String[]

    # An unbounded show section falls back to a default rather than the screen.
    @test length(flines(sections((:m, rand(50, 50), nothing)), 40, 60)) <= F.DEFAULT_SHOW_ROWS
end

@testitem "footer_window_shows_the_end" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F
    ten = ["line $i" for i in 1:10]

    # Content that fits is left alone.
    @test F.window(ten, 20) == ten
    @test F.window(ten, 0) == String[]

    # Content that does not fit shows its end, not its beginning: the reason to
    # watch a footer is what just happened.
    @test F.window(ten, 3) == ["line 8", "line 9", "line 10"]
end

@testitem "footer_section_world_age" tags = [:footer] setup = [FooterHarness] begin
    flines, sections = FooterHarness.flines, FooterHarness.sections

    # The painting task outlives everything typed at the prompt afterwards, so
    # rendering a closure defined later is a world age error unless the call goes
    # through invokelatest. @eval is what puts the closure in a newer world than the
    # task waiting below.
    work = Channel{Any}(1)
    done = Channel{Any}(1)
    painter = Threads.@spawn put!(done, flines(take!(work), 24, 5))
    put!(work, sections((:r, @eval(w -> "-"^w), nothing)))
    @test take!(done) == ["-----"]
    wait(painter)
end

@testitem "footer_section_that_throws" tags = [:footer] setup = [FooterHarness] begin
    flines, sections = FooterHarness.flines, FooterHarness.sections

    boom(_) = error("no")
    lines = flines(
        sections((:a, "before", nothing), (:bad, boom, nothing), (:b, "after", nothing)), 24, 80
    )
    # A section that throws loses its own rows and reports the error there, rather
    # than taking the footer down with it.
    @test length(lines) == 3
    @test lines[1] == "before"
    @test occursin("bad", lines[2]) && occursin("no", lines[2])
    @test lines[3] == "after"

    # A multi-line error message keeps to the one row.
    multiline(_) = error("first\nsecond")
    lines = flines(sections((:bad, multiline, nothing)), 24, 80)
    @test length(lines) == 1
    @test occursin("first", lines[1]) && !occursin("second", lines[1])
end

@testitem "footer_paint_row_arithmetic" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F

    # Same line count as last time: no scroll region change, no scrolling, cursor
    # saved and restored so the prompt is untouched.
    @test F.paint(2, ["a", "b"], 24, 80) ==
        "\e7" * "\e[23;1Ha\e[0m\e[K" * "\e[24;1Hb\e[0m\e[K" * "\e8"

    # Growing by one row shrinks the scroll region, so scroll the old region up
    # first to push the prompt clear of the row the footer is about to claim, then
    # compensate the restored cursor by the same amount.
    @test F.paint(0, ["a"], 24, 80) ==
        "\e7" * "\e[1S" * "\e[1;23r" * "\e[24;1Ha\e[0m\e[K" * "\e8" * "\e[1A"

    # Shrinking grows the region back, and the rows it reclaims must be cleared of
    # stale footer text. No scrolling needed.
    @test F.paint(3, ["a"], 24, 80) ==
        "\e7" * "\e[1;23r" * "\e[24;1Ha\e[0m\e[K" * "\e[22;1H\e[K" * "\e[23;1H\e[K" * "\e8"

    @test F.paint(2, String[], 24, 80) ==
        "\e7" * "\e[1;24r" * "\e[23;1H\e[K" * "\e[24;1H\e[K" * "\e8"

    @test F.paint(0, String[], 24, 80) == ""

    # The footer leaves the scrolling region two rows, the fewest DECSTBM accepts.
    @test F.paint(0, ["a", "b", "c"], 3, 80) ==
        "\e7" * "\e[1S" * "\e[1;2r" * "\e[3;1Ha\e[0m\e[K" * "\e8" * "\e[1A"
    @test F.default_rows("text", 3) == 1

    # After a resize or anything else that clobbers DECSTBM, the region must be set
    # even though the footer has not changed size.
    @test F.paint(1, ["a"], 24, 80; force_region = true) ==
        "\e7" * "\e[1;23r" * "\e[24;1Ha\e[0m\e[K" * "\e8"
    @test F.paint(0, String[], 24, 80; force_region = true) == "\e7" * "\e[1;24r" * "\e8"

    @test F.paint(1, ["abcdef"], 24, 3) == "\e7" * "\e[24;1Habc\e[0m\e[K" * "\e8"
end

@testitem "footer_clear_region_sequence" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F

    # The bottom row belongs to the footer and is left alone.
    @test F.clear_region_sequence(4, 1) ==
        "\e[1;1H\e[K" * "\e[2;1H\e[K" * "\e[3;1H\e[K" * "\e[1;1H"
    # No footer, so the whole screen goes.
    @test F.clear_region_sequence(2, 0) == "\e[1;1H\e[K" * "\e[2;1H\e[K" * "\e[1;1H"
    # A footer filling the screen leaves nothing to clear.
    @test F.clear_region_sequence(2, 2) == "\e[1;1H"
end

@testitem "footer_rows_left_behind_by_a_resize" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F

    # Rows that still fit take one row each. One that does not comes back as
    # several: 95 columns at 47 is 47, 47 and a remainder.
    @test F.reflowed_rows([10, 20], 40) == 2
    @test F.reflowed_rows([95], 47) == 3
    @test F.reflowed_rows([94], 47) == 2
    @test F.reflowed_rows([95], 32) == 3
    @test F.reflowed_rows([0], 40) == 1
    @test F.reflowed_rows(Int[], 40) == 0

    # Gaining height strands the old footer at its old row numbers; losing height
    # keeps it in the rows the new one claims.
    @test F.vacated_rows(2, 20, 24) == 19:20
    @test F.vacated_rows(2, 24, 20) == 1:0
    @test F.vacated_rows(2, 24, 24) == 1:0
    @test F.vacated_rows(0, 20, 24) == 1:0
    @test F.vacated_rows(2, 0, 24) == 1:0

    painted(rows, height, width, widths) = F.Painted(rows, height, width, widths)

    # Nothing changed, so nothing was abandoned.
    @test F.abandoned_rows(painted(1, 24, 80, [10]), 1, 24, 80) == Int[]
    # Gaining height leaves the old footer at its old row numbers.
    @test F.abandoned_rows(painted(2, 20, 80, [10, 10]), 2, 24, 80) == [19, 20]
    # Narrowing past a row's width leaves the terminal's rewrap of it above the new
    # footer: 95 columns at 47 is three rows.
    @test F.abandoned_rows(painted(1, 24, 100, [95]), 1, 24, 47) == [21, 22, 23]
    # Narrowing that forces no rewrap moves nothing.
    @test F.abandoned_rows(painted(1, 24, 100, [10]), 1, 24, 47) == Int[]
    # Both at once are both accounted for.
    both = F.abandoned_rows(painted(1, 20, 100, [95]), 1, 24, 47)
    @test 20 in both && 21 in both
end

@testitem "footer_repaint_claims_and_keeps_its_rows" tags = [:footer] setup = [FooterHarness] begin
    F, harness, written = FooterHarness.F, FooterHarness.harness, FooterHarness.written

    footer, buf = harness(24, 80)
    F.set!(:a, "one", footer)
    F.repaint!(footer)
    # Nothing is reserved yet, so the screen scrolls up to make room.
    @test written(buf) == "\e7\e[1S\e[1;23r\e[24;1Hone\e[0m\e[K\e8\e[1A"
    @test footer.painted.rows == 1

    # Same rows, same contents, so only the contents are rewritten.
    F.repaint!(footer)
    @test written(buf) == "\e7\e[24;1Hone\e[0m\e[K\e8"
end

@testitem "footer_waits_out_a_prompt_eval" tags = [:footer] setup = [FooterHarness] begin
    F, harness, written = FooterHarness.F, FooterHarness.harness, FooterHarness.written

    # Code run at the prompt owns the screen until it returns: `less` or `vim` on the
    # alternate screen would be drawn over. The paint waits, then claims the region.
    @test F.prompt_evaluating((; in_eval = true))
    @test !F.prompt_evaluating((; in_eval = false))
    @test !F.prompt_evaluating(nothing)

    footer, buf = harness(24, 80)
    F.set!(:a, "one", footer)
    F.repaint!(footer; paused = true)
    @test written(buf) == ""
    F.repaint!(footer)
    @test written(buf) == "\e7\e[1S\e[1;23r\e[24;1Hone\e[0m\e[K\e8\e[1A"
end

@testitem "footer_writes_under_its_lock" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F

    # A repaint written after `disable!` released the region would claim it again,
    # so every write holds the lock `disable!` takes.
    mutable struct LockProbe <: IO
        footer::Any
        held::Vector{Bool}
    end
    function Base.unsafe_write(probe::LockProbe, ::Ptr{UInt8}, n::UInt)
        push!(probe.held, islocked(probe.footer.lock))
        return n
    end
    Base.displaysize(::LockProbe) = (24, 80)

    probe = LockProbe(nothing, Bool[])
    footer = F.Footer(probe)
    probe.footer = footer
    footer.enabled = true
    F.set!(:a, "one", footer)
    F.repaint!(footer)
    F.disable!(footer)
    @test length(probe.held) == 2
    @test all(probe.held)
end

@testitem "footer_repaint_across_a_resize" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F
    harness, resize, written = FooterHarness.harness, FooterHarness.resize, FooterHarness.written

    footer, buf = harness(24, 80)
    F.set!(:a, "one", footer)
    F.repaint!(footer)
    take!(buf)

    resize(footer, 20, 80)
    F.repaint!(footer)
    # The reserved rows still hold the old footer, so they are painted over in
    # place. Scrolling here would lift the old copy into the scrolling region and
    # leave it stranded above the new one.
    @test written(buf) == "\e7\e[1;19r\e[20;1Hone\e[0m\e[K\e8"
    @test footer.painted.height == 20

    # Only the one extra row is claimed, not both of them again.
    F.set!(:b, "two", footer)
    F.repaint!(footer)
    @test written(buf) == "\e7\e[1S\e[1;18r\e[19;1Hone\e[0m\e[K\e[20;1Htwo\e[0m\e[K\e8\e[1A"

    # Narrowing is a resize too: same rows, so nothing moves, but the text has to be
    # re-truncated and the region set again since the terminal will have reset it.
    F.clear!(:b, footer)
    F.repaint!(footer)
    take!(buf)
    resize(footer, 20, 3)
    F.repaint!(footer)
    @test written(buf) == "\e7\e[1;19r\e[20;1Hone\e[0m\e[K\e8"
    @test footer.painted.width == 3
end

@testitem "footer_clears_what_a_resize_stranded" tags = [:footer] setup = [FooterHarness] begin
    F = FooterHarness.F
    harness, resize, written = FooterHarness.harness, FooterHarness.resize, FooterHarness.written

    # A row wider than the new width comes back as two, in the scrolling region,
    # above the freshly painted footer.
    footer, buf = harness(24, 100)
    F.set!(:wide, "w"^95, footer)
    F.repaint!(footer)
    @test footer.painted.widths == [95]
    take!(buf)

    resize(footer, 24, 47)
    F.repaint!(footer)
    # 95 columns becomes three rows at 47, ending just above the footer.
    narrowed = written(buf)
    @test occursin("\e[21;1H\e[K", narrowed)
    @test occursin("\e[22;1H\e[K", narrowed)
    @test occursin("\e[23;1H\e[K", narrowed)

    # Narrowing that does not force a rewrap moves nothing, so nothing above the
    # footer may be cleared.
    unmoved, unmoved_buf = harness(24, 100)
    F.set!(:narrow, "abc", unmoved)
    F.repaint!(unmoved)
    take!(unmoved_buf)
    resize(unmoved, 24, 50)
    F.repaint!(unmoved)
    @test !occursin("\e[23;1H\e[K", written(unmoved_buf))

    # Growing the terminal keeps the top fixed, so rows 19 and 20 still hold the old
    # footer and are no longer part of it: blanked before the new copy is drawn.
    grown, grown_buf = harness(20, 80)
    F.set!(:a, "one\ntwo", grown)
    F.repaint!(grown)
    take!(grown_buf)
    resize(grown, 24, 80)
    F.repaint!(grown)
    @test written(grown_buf) ==
        "\e7\e[1;22r" * "\e[19;1H\e[K\e[20;1H\e[K" *
        "\e[23;1Hone\e[0m\e[K\e[24;1Htwo\e[0m\e[K" * "\e8"
end

@testitem "footer_sections_keep_their_order" tags = [:footer] setup = [FooterHarness] begin
    F, harness, flines = FooterHarness.F, FooterHarness.harness, FooterHarness.flines

    footer, _ = harness(24, 80)
    lines() = flines(footer.sections, 24, 80)

    F.set!(:a, "one", footer)
    F.set!(:b, "two", footer)
    @test lines() == ["one", "two"]

    # Setting a label again replaces it in place, keeping its position.
    F.set!(:a, "ONE", footer)
    @test lines() == ["ONE", "two"]

    F.clear!(:a, footer)
    @test lines() == ["two"]

    F.clear!(footer)
    @test lines() == String[]

    F.set!(:m, rand(20, 20), footer; rows = 4)
    @test 1 <= length(lines()) <= 4
end

@testitem "footer_refresh_forces_the_region_back" tags = [:footer] setup = [FooterHarness] begin
    F, harness, written = FooterHarness.F, FooterHarness.harness, FooterHarness.written

    footer, buf = harness(24, 80)
    F.set!(:a, "one", footer)
    F.repaint!(footer)
    take!(buf)

    # Without it, an unchanged footer only rewrites its own rows, which would not
    # restore a scrolling region something else had reset.
    F.repaint!(footer)
    @test written(buf) == "\e7\e[24;1Hone\e[0m\e[K\e8"

    F.refresh!(footer)
    F.repaint!(footer)
    @test written(buf) == "\e7\e[1;23r\e[24;1Hone\e[0m\e[K\e8"
end

@testitem "footer_enable_and_disable" tags = [:footer] setup = [FooterHarness] begin
    F, harness, written = FooterHarness.F, FooterHarness.harness, FooterHarness.written

    # Piped or redirected output has no terminal to draw on, and the escape
    # sequences would be corruption rather than a footer.
    refused = F.Footer(IOBuffer())
    @test F.enable!(refused; io = IOBuffer()) == false
    @test refused.enabled == false
    @test F.terminal_output(IOBuffer()) == false
    @test F.terminal_output(IOContext(IOBuffer(), :color => true)) == false
    @test F.terminal_output(Base.DevNull()) == false

    footer, buf = harness(24, 80)
    F.set!(:a, "one", footer)
    F.repaint!(footer)
    take!(buf)

    F.disable!(footer)
    @test written(buf) == "\e7\e[1;24r\e[24;1H\e[K\e8"
    @test footer.enabled == false
    @test footer.painted.rows == 0
    @test footer.painted.height == 0

    # Idempotent: a second call has nothing left to give back.
    F.disable!(footer)
    @test written(buf) == ""

    # Sections are kept, so a disabled footer draws nothing but restores what it
    # had when it comes back. The recorded paint was reset, so the return is
    # treated as a first paint and scrolls to claim its row.
    F.repaint!(footer)
    @test written(buf) == ""
    footer.enabled = true
    footer.stale = true
    F.repaint!(footer)
    @test written(buf) == "\e7\e[1S\e[1;23r\e[24;1Hone\e[0m\e[K\e8\e[1A"
end

@testitem "footer_upkeep_reaches_keys_installed_later" tags = [:footer] begin
    import REPLicant

    # On Julia 1.11+ a footer enabled from startup.jl starts upkeep before REPL, and so
    # the extension's key binding, has loaded. A fresh process keeps the stand-in
    # binding out of this one.
    script = """
    using REPLicant
    F = REPLicant.Footers
    footer = F.Footer(IOContext(IOBuffer(), :displaysize => (24, 80)))
    Threads.@spawn F.upkeep(footer)
    sleep(2 * F.UPKEEP_TICK)
    called = Ref(false)
    @eval F.__install_keys(::Nothing) = (\$called[] = true; true)
    deadline = time() + 10
    while !called[] && time() < deadline
        sleep(0.1)
    end
    print(called[])
    """
    cmd = `$(Base.julia_cmd()) --project=$(pkgdir(REPLicant)) --startup-file=no -e $script`
    @test read(pipeline(cmd; stderr = devnull), String) == "true"
end
