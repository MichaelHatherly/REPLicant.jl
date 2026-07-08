# The activity log records human-typed and agent-eval'd activity into a bounded ring,
# read back over the socket with a `log` request. These cover the ring and render
# directly, the socket round trip, and the human capture path (the tee) without a
# live REPL.

@testitem "activity_ring_and_render" tags = [:activity] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()

    # Push past the cap: the oldest entries are evicted, the ring holds MAX_LOG_ENTRIES.
    total = REPLicant.MAX_LOG_ENTRIES + 5
    for i in 1:total
        REPLicant._record_activity(:socket, "x$i = $i", "$i", false)
    end
    @test length(REPLicant.ACTIVITY_LOG) == REPLicant.MAX_LOG_ENTRIES
    # Sequence numbers are monotonic and reach the total pushed.
    @test REPLicant.ACTIVITY_LOG[end].seq == total
    @test issorted(entry.seq for entry in REPLicant.ACTIVITY_LOG)

    # Default render window is the last DEFAULT_LOG_ENTRIES; an explicit count caps it.
    body = REPLicant._render_activity_log("5")
    @test count("[#", body) == 5
    @test contains(body, "5 entries")
    @test contains(body, "x$(total) = $(total)")
    # The oldest survivor is entry seq 6 (1-5 evicted); it is not in a last-5 window.
    @test !contains(body, "x1 = 1")

    # `since` returns only entries past the cursor, for incremental catchup.
    since = REPLicant._render_activity_log("since=$(total - 2)")
    @test count("[#", since) == 2
    @test contains(since, "#$(total)")
    @test !contains(since, "#$(total - 3)")
end

@testitem "activity_cap_utf8" tags = [:activity] setup = [Utilities] begin
    import REPLicant

    # A multibyte character split at the byte cap must not produce invalid UTF-8.
    output = repeat("π", REPLicant.MAX_ENTRY_OUTPUT_BYTES)  # 2 bytes each, over the cap
    capped = REPLicant._cap(output)
    @test isvalid(capped)
    @test contains(capped, "output truncated")
    @test ncodeunits(capped) <= REPLicant.MAX_ENTRY_OUTPUT_BYTES + ncodeunits("\n[output truncated]")

    # Under the cap, the text is returned unchanged.
    @test REPLicant._cap("short") == "short"
end

@testitem "activity_skips_empty_code" tags = [:activity] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()
    REPLicant._record_activity(:socket, "   ", "output", false)
    @test isempty(REPLicant.ACTIVITY_LOG)
    @test contains(REPLicant._render_activity_log(""), "no matching entries")
end

@testitem "activity_socket_roundtrip" tags = [:activity] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        Utilities.reset_activity()

        Utilities.request(port, "x = 41")
        Utilities.request(port, "?sin")   # help query, recorded like any eval
        Utilities.requestframe(port, REPLicant.REQUEST_EVAL, "undefined_var")  # error

        # A liveness ping is answered off the worker queue and never recorded.
        Utilities.requestframe(port, REPLicant.REQUEST_PING, "")

        frame = Utilities.requestframe(port, REPLicant.REQUEST_LOG, "")
        @test frame.type == REPLicant.RESPONSE_OK
        body = frame.body
        # Three evals recorded, the ping absent.
        @test count("[#", body) == 3
        @test contains(body, "x = 41")
        @test contains(body, "socket")
        # The error eval carries its ERROR text in the recorded output.
        @test contains(body, "undefined_var")
        @test contains(body, "UndefVarError")

        # The log request itself is not recorded, so a second read shows the same three.
        again = Utilities.requestframe(port, REPLicant.REQUEST_LOG, "")
        @test count("[#", again.body) == 3

        # `since` past the second entry returns only the third.
        newer = Utilities.requestframe(port, REPLicant.REQUEST_LOG, "since=2")
        @test count("[#", newer.body) == 1
        @test contains(newer.body, "#3")
    end
end

@testitem "activity_human_capture" tags = [:activity] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()

    # Drive the real tee via a Router writing to a throwaway backing stream, so no
    # process-wide stdout redirect is needed. Unbound CAPTURE_TARGET means the writes
    # are treated as the human's and tee into the open entry.
    backing = IOBuffer()
    router = REPLicant.Router(Ref{IO}(backing))

    REPLicant._record_repl_input("x = 41")
    print(router, "hello\n")
    show(IOContext(router, :color => false), "text/plain", 42)

    body = REPLicant._render_activity_log("")
    @test contains(body, "repl")
    @test contains(body, "x = 41")
    @test contains(body, "hello")
    @test contains(body, "42")
    # The writes still reached the backing stream.
    @test contains(String(take!(backing)), "hello")

    # A second input finalizes the first entry into the ring and opens a new one.
    REPLicant._record_repl_input("y = 2")
    @test length(REPLicant.ACTIVITY_LOG) == 1
    @test REPLicant.ACTIVITY_LOG[1].code == "x = 41"
    @test contains(REPLicant.ACTIVITY_LOG[1].output, "hello")
end

@testitem "activity_captures_repl_display" tags = [:activity] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()
    REPLicant._record_repl_input("hyp = 6 * 7")
    # The REPL renders a bare result through the display stack, not the redirected
    # stdout. RouterDisplay tees it into the open entry, then declines (MethodError)
    # so the REPL's own display still shows it on the terminal.
    @test_throws MethodError Base.display(REPLicant.RouterDisplay(), MIME"text/plain"(), 42)
    body = REPLicant._render_activity_log("")
    @test contains(body, "hyp = 6 * 7")
    @test contains(body, "42")
end

@testitem "activity_human_output_capped" tags = [:activity] setup = [Utilities] begin
    import REPLicant

    Utilities.reset_activity()
    router = REPLicant.Router(Ref{IO}(IOBuffer()))

    REPLicant._record_repl_input("noisy()")
    print(router, repeat("a", REPLicant.MAX_ENTRY_OUTPUT_BYTES + 500))
    entry = REPLicant.CURRENT_HUMAN_ENTRY[]
    @test entry !== nothing
    @test length(entry.out) == REPLicant.MAX_ENTRY_OUTPUT_BYTES
end

@testitem "activity_deparse_and_transform" tags = [:activity] setup = [Utilities] begin
    import REPLicant
    import REPL  # trigger the REPL extension so the transform/deparse are defined

    Utilities.reset_activity()
    ext = Base.get_extension(REPLicant, :REPLicantREPLExt)
    @test ext !== nothing

    # Deparse reproduces the typed code from the parsed expression.
    @test ext._deparse(:(x = 1)) == "x = 1"
    # Top-level multi-statement input joins on newlines.
    @test ext._deparse(Meta.parseall("a\nb")) == "a\nb"

    # The transform is an identity: it returns its input unchanged, and records it.
    expr = :(z = 3)
    @test ext._repl_input_transform(expr) === expr
    @test contains(REPLicant._render_activity_log(""), "z = 3")
end
