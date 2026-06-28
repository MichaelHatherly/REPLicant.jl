@testitem "client_arg_parsing" tags = [:cli] begin
    import REPLicant

    basic = REPLicant._parse_args(["--port=8000", "-e", "x"])
    @test basic.port == 8000
    @test basic.code == "x"
    @test basic.project == ""
    @test basic.name == ""

    spaced =
        REPLicant._parse_args(["--port", "8001", "--project", "p", "--name", "n"])
    @test spaced.port == 8001
    @test spaced.project == "p"
    @test spaced.name == "n"
    @test isnothing(spaced.code)

    joined = REPLicant._parse_args(["--project=/tmp/x", "--name=lbl", "--eval", "1"])
    @test joined.project == "/tmp/x"
    @test joined.name == "lbl"
    @test joined.code == "1"

    @test_throws Exception REPLicant._parse_args(["--port=abc"])
    @test_throws Exception REPLicant._parse_args(["--port"])
    @test_throws Exception REPLicant._parse_args(["--bogus"])
end

@testitem "client_timeout_parsing" tags = [:cli] begin
    import REPLicant

    # No --timeout means no bound: the client waits as long as the eval runs.
    @test isnothing(REPLicant._parse_args(["-e", "1"]).timeout)

    @test REPLicant._parse_args(["--timeout=2.5", "-e", "1"]).timeout == 2.5
    @test REPLicant._parse_args(["--timeout", "3", "-e", "1"]).timeout == 3.0

    @test_throws Exception REPLicant._parse_args(["--timeout=abc"])
    @test_throws Exception REPLicant._parse_args(["--timeout=0"])
    @test_throws Exception REPLicant._parse_args(["--timeout=-1"])
    @test_throws Exception REPLicant._parse_args(["--timeout"])
end

@testitem "client_timeout_frees_caller" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        out = IOBuffer()
        err = IOBuffer()
        # A non-returning eval holds the worker; --timeout frees the caller without
        # waiting for a response.
        elapsed = @elapsed code =
            REPLicant.cli(["--port=$port", "--timeout=0.5", "-e", "sleep(3)"]; out, err)
        @test code == 1
        @test elapsed < 2
        @test isempty(String(take!(out)))
        # The error names the timeout and points at kill as the recovery.
        message = String(take!(err))
        @test contains(message, "kill")
        # The server is still alive: pings are answered off the wedged worker.
        @test REPLicant._ping(port)
    end
end

@testitem "status_formatting" tags = [:cli] begin
    import REPLicant
    import Dates

    # An empty pong body is an idle server.
    @test REPLicant._format_status("") == "idle"

    # A timestamp marks a busy server, rendered with elapsed seconds.
    marker = string(Dates.now() - Dates.Second(5))
    rendered = REPLicant._format_status(marker)
    @test contains(rendered, "busy")
    @test contains(rendered, "s")

    # A garbled marker still reads as busy rather than crashing.
    @test contains(REPLicant._format_status("not-a-date"), "busy")
end

@testitem "ls_reports_busy_state" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        # An idle server: empty pong body, STATUS column shows idle.
        @test REPLicant._ping_status(port) == ""
        out = IOBuffer()
        @test REPLicant.cli(["ls"]; out) == 0
        listing = String(take!(out))
        @test contains(listing, "STATUS")
        @test contains(listing, "idle")

        # Occupy the worker; the pong now carries a busy-since marker and ls
        # renders the server busy.
        busy = @async Utilities.request(port, "sleep(2)")
        sleep(0.5)
        @test !isempty(REPLicant._ping_status(port))
        @test REPLicant.cli(["ls"]; out) == 0
        @test contains(String(take!(out)), "busy")
        wait(busy)
    end
end

@testitem "client_send_and_ls" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        # Auto-select the single live server.
        out = IOBuffer()
        @test REPLicant.cli(["-e", "6 * 7"]; out) == 0
        @test String(take!(out)) == "42\n"

        # Explicit port.
        @test REPLicant.cli(["--port=$port", "-e", "1 + 1"]; out) == 0
        @test String(take!(out)) == "2\n"

        # Discovery lists the running server.
        @test REPLicant.cli(["ls"]; out) == 0
        listing = String(take!(out))
        @test contains(listing, string(port))
        @test contains(listing, "PORT")

        # Label this server (CURRENT points at it) and route by name.
        @test REPLicant.label!("tests") == "tests"
        @test REPLicant.cli(["--name=tests", "-e", "2 + 3"]; out) == 0
        @test String(take!(out)) == "5\n"

        # The label shows up in discovery.
        @test REPLicant.cli(["ls"]; out) == 0
        @test contains(String(take!(out)), "tests")

        # An unknown name fails with a non-zero code and a candidate listing.
        err = IOBuffer()
        @test REPLicant.cli(["--name=missing", "-e", "1"]; out, err) == 1
        @test contains(String(take!(err)), "no server named")
    end
end

@testitem "client_tolerates_closed_output_pipe" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    # A sink that fails every write the way a pipe closed by `| head` does.
    struct BrokenPipe <: IO end
    Base.unsafe_write(::BrokenPipe, ::Ptr{UInt8}, ::UInt) =
        throw(Base.IOError("write: broken pipe (EPIPE)", -32))

    # The payload write is swallowed, not propagated.
    @test isnothing(REPLicant._write_payload(BrokenPipe(), "42"))

    # An EPIPE while writing the result does not crash the client; it still
    # reports the evaluation's exit code.
    Utilities.withserver() do server, mod, port
        @test REPLicant._send(port, "2 + 2"; out = BrokenPipe()) == 0
    end
end

@testitem "client_appends_trailing_newline" tags = [:cli] begin
    import REPLicant

    # A non-empty result without its own newline gets one, so output does not run
    # into the shell prompt.
    out = IOBuffer()
    REPLicant._write_payload(out, "42")
    @test String(take!(out)) == "42\n"

    # An already-terminated payload is left alone.
    REPLicant._write_payload(out, "42\n")
    @test String(take!(out)) == "42\n"

    # An empty payload writes nothing.
    REPLicant._write_payload(out, "")
    @test isempty(String(take!(out)))
end

@testitem "client_eval_error_routes_to_stderr" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        out = IOBuffer()
        err = IOBuffer()
        # An evaluation error exits non-zero, with the error on stderr and nothing
        # on stdout.
        @test REPLicant.cli(["--port=$port", "-e", "undefined_variable"]; out, err) == 1
        @test isempty(String(take!(out)))
        @test contains(String(take!(err)), "UndefVarError")
    end
end

@testitem "client_selection_cascade" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withproject() do start, registry
        _, port1 = start()
        _, port2 = start()

        # Two unlabeled servers in one project: ambiguous, lists candidates.
        err = IOBuffer()
        @test REPLicant.cli(["-e", "1"]; out = IOBuffer(), err) == 1
        message = String(take!(err))
        @test contains(message, "multiple servers")
        @test contains(message, string(port1))
        @test contains(message, string(port2))

        # Explicit port still resolves.
        out = IOBuffer()
        @test REPLicant.cli(["--port=$port2", "-e", "20 + 22"]; out) == 0
        @test String(take!(out)) == "42\n"

        # Labeling disambiguates by name. label! tags the most recently started
        # server (CURRENT), which is port2.
        @test REPLicant.label!("second") == "second"
        @test REPLicant.cli(["--name=second", "-e", "21 + 21"]; out) == 0
        @test String(take!(out)) == "42\n"
    end
end

@testitem "client_no_servers" tags = [:cli] begin
    import REPLicant

    mktempdir() do registry
        withenv("REPLICANT_DIR" => registry) do
            err = IOBuffer()
            @test REPLicant.cli(["-e", "1"]; out = IOBuffer(), err) == 1
            @test contains(String(take!(err)), "no running REPLicant servers")
        end
    end
end

@testitem "client_script_arg_parsing" tags = [:cli] begin
    import REPLicant

    bare = REPLicant._parse_args(["script.jl"])
    @test bare.file == "script.jl"
    @test bare.script_args == String[]
    @test isnothing(bare.code)

    withargs = REPLicant._parse_args(["script.jl", "a", "b"])
    @test withargs.file == "script.jl"
    @test withargs.script_args == ["a", "b"]

    # Flags before the script are client flags; everything after the script is
    # passed to it verbatim, even flag-shaped tokens.
    mixed = REPLicant._parse_args(["--name", "n", "script.jl", "--flag", "x"])
    @test mixed.name == "n"
    @test mixed.file == "script.jl"
    @test mixed.script_args == ["--flag", "x"]

    # A script file and -e/--eval are mutually exclusive.
    @test_throws Exception REPLicant._parse_args(["-e", "1", "script.jl"])

    # A positional that is not a .jl path is still rejected.
    @test_throws Exception REPLicant._parse_args(["bogus"])
end

@testitem "client_dir_and_module_parsing" tags = [:cli] begin
    import REPLicant

    parsed = REPLicant._parse_args(["--dir=/tmp/x", "--module=Sess", "-e", "1"])
    @test parsed.dir == "/tmp/x"
    @test parsed.mod == "Sess"

    # Defaults are empty: the client fills in the working directory, and the
    # default session is used.
    bare = REPLicant._parse_args(["-e", "1"])
    @test bare.dir == ""
    @test bare.mod == ""
end

@testitem "client_eval_runs_in_caller_dir" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        mktempdir() do dir
            write(joinpath(dir, "marker.txt"), "hi")
            out = IOBuffer()
            # A relative path resolves against --dir, not the server's startup cwd.
            @test REPLicant.cli(["--port=$port", "--dir=$dir", "-e", "isfile(\"marker.txt\")"]; out) == 0
            @test strip(String(take!(out))) == "true"

            # A `cd` inside one eval does not leak into the next: the following eval
            # still resolves the relative path against --dir. Checked via the marker
            # file rather than `pwd()` to avoid Windows short/long path mismatches.
            @test REPLicant.cli(["--port=$port", "--dir=$dir", "-e", "cd(\"..\"); 1"]; out) == 0
            take!(out)
            @test REPLicant.cli(["--port=$port", "--dir=$dir", "-e", "isfile(\"marker.txt\")"]; out) == 0
            @test strip(String(take!(out))) == "true"
        end
    end
end

@testitem "client_module_isolation" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        out = IOBuffer()
        # State set in a named session persists across calls under that name.
        @test REPLicant.cli(["--port=$port", "--module=Sess", "-e", "z = 99"]; out) == 0
        take!(out)
        @test REPLicant.cli(["--port=$port", "--module=Sess", "-e", "z"]; out) == 0
        @test strip(String(take!(out))) == "99"

        # It is invisible in the default session and in another named session.
        err = IOBuffer()
        @test REPLicant.cli(["--port=$port", "-e", "z"]; out, err) == 1
        @test contains(String(take!(err)), "UndefVarError")
        other = IOBuffer()
        @test REPLicant.cli(["--port=$port", "--module=Other", "-e", "z"]; out, err = other) == 1
        @test contains(String(take!(other)), "UndefVarError")
    end
end

@testitem "client_reset_clears_module" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        REPLicant.cli(["--port=$port", "--module=Sess", "-e", "keep = 5"]; out = IOBuffer())

        out = IOBuffer()
        @test REPLicant.cli(["reset", "--port=$port", "--module=Sess"]; out) == 0
        @test contains(String(take!(out)), "reset module Sess")

        err = IOBuffer()
        @test REPLicant.cli(["--port=$port", "--module=Sess", "-e", "keep"]; out = IOBuffer(), err) == 1
        @test contains(String(take!(err)), "UndefVarError")

        # The default session has no resettable name.
        no_name = IOBuffer()
        @test REPLicant.cli(["reset", "--port=$port"]; out = IOBuffer(), err = no_name) == 1
        @test contains(String(take!(no_name)), "needs --module")
    end
end

@testitem "select_entry_warns_cross_project" tags = [:cli] begin
    import REPLicant

    # A server rooted at one project, a caller in an unrelated one: the lone server
    # is still chosen, with a warning that names the foreign project.
    entries = [REPLicant.RegistryEntry(9001, "/some/project/a", "", "1.12", "111", "t")]
    err = IOBuffer()
    chosen = REPLicant._select_entry(entries, "/different/place", ""; err)
    @test chosen.port == 9001
    message = String(take!(err))
    @test contains(message, "no server for")
    @test contains(message, "/some/project/a")
end

@testitem "client_cross_project_warns_through_cli" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        out = IOBuffer()
        err = IOBuffer()
        # Resolve from a directory the lone server does not own: the eval still runs,
        # the warning goes to stderr, and stdout carries only the result.
        @test REPLicant.cli(["--project=/no/such/project", "-e", "6 * 7"]; out, err) == 0
        @test strip(String(take!(out))) == "42"
        @test contains(String(take!(err)), "no server for")
    end
end

@testitem "client_channel_launcher" tags = [:cli] begin
    import REPLicant

    # `--channel` parses (as `_start_server` sees it, after `start` is stripped),
    # defaulting to empty.
    @test REPLicant._parse_args(["--channel=1.10"]).channel == "1.10"
    @test REPLicant._parse_args(String[]).channel == ""

    # The launcher is `julia` on PATH by default, or `julia +<channel>` for a version.
    @test REPLicant._server_julia("") == `julia`
    @test REPLicant._server_julia("1.10") == `julia +1.10`
end

@testitem "client_start_spawns_detached_server" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    # `start` spawns `julia` on PATH (pkgimages on), but the test runner runs under
    # `--check-bounds=yes` (pkgimages off), so REPLicant's image is not yet built for
    # this invocation. Build it now, unbounded, so the timed start below registers
    # instead of compiling cold (slow enough to time out on Windows). In production
    # the image already exists.
    run(
        pipeline(
            `julia --project=$(pkgdir(REPLicant)) --startup-file=no -e "using REPLicant"`;
            stdout = devnull,
            stderr = devnull,
        ),
    )

    mktempdir() do registry
        withenv("REPLICANT_DIR" => registry) do
            mktempdir() do work
                try
                    out = IOBuffer()
                    # Point the spawned process at REPLicant's own project so `using
                    # REPLicant` resolves without a configured global env. `--name`
                    # exercises the detached label path.
                    rc = REPLicant.cli(
                        ["start", "--dir=$work", "--name=api", "--project=$(pkgdir(REPLicant))"]; out,
                    )
                    @test rc == 0
                    message = String(take!(out))
                    @test contains(message, "started REPLicant server")
                    port = parse(Int, match(r"port (\d+)", message).captures[1])

                    # The label took effect and the server evaluates.
                    listing = IOBuffer()
                    @test REPLicant.cli(["ls"]; out = listing) == 0
                    @test contains(String(take!(listing)), "api")
                    result = IOBuffer()
                    @test REPLicant.cli(["--port=$port", "-e", "6 * 7"]; out = result) == 0
                    @test strip(String(take!(result))) == "42"
                finally
                    # Kill any server registered in this isolated registry, so a
                    # failure before the port is parsed never leaks the process.
                    for entry in REPLicant._read_entries()
                        pid = tryparse(Int, entry.pid)
                        isnothing(pid) || REPLicant._signal_process(pid, REPLicant.SIGKILL)
                    end
                end
            end
        end
    end
end

@testitem "client_runs_script_file" tags = [:cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        out = IOBuffer()
        err = IOBuffer()
        mktempdir() do dir
            # ARGS before any script run, to verify the restore afterward.
            @test REPLicant.cli(["-e", "repr(ARGS)"]; out) == 0
            before = String(take!(out))

            # A script that prints, reads ARGS, and ends in a value.
            script = joinpath(dir, "demo.jl")
            write(script, "println(\"args: \", join(ARGS, \",\"))\n21 * 2")
            @test REPLicant.cli([script, "X", "Y"]; out) == 0
            @test String(take!(out)) == "args: X,Y\n42\n"

            # A definition made by the script persists in the session.
            write(script, "const FROM_SCRIPT = 7")
            @test REPLicant.cli([script]; out) == 0
            take!(out)
            @test REPLicant.cli(["-e", "FROM_SCRIPT"]; out) == 0
            @test String(take!(out)) == "7\n"

            # ARGS is restored after the run, not left holding the script's args.
            @test REPLicant.cli(["-e", "repr(ARGS)"]; out) == 0
            @test String(take!(out)) == before

            # An error in the script names the file, not REPL[N].
            bad = joinpath(dir, "boom.jl")
            write(bad, "error(\"kaboom\")")
            @test REPLicant.cli([bad]; out, err) == 1
            trace = String(take!(err))
            @test contains(trace, "kaboom")
            @test contains(trace, "boom.jl")

            # A missing file is reported, not forwarded.
            @test REPLicant.cli([joinpath(dir, "nope.jl")]; out, err) == 1
            @test contains(String(take!(err)), "file not found")
        end
    end
end
