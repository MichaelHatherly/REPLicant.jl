@testitem "client_arg_parsing" tags = [:cli] begin
    import REPLicant

    basic = REPLicant._parse_client_args(["--port=8000", "-e", "x"])
    @test basic.port == 8000
    @test basic.code == "x"
    @test basic.project == ""
    @test basic.name == ""

    spaced =
        REPLicant._parse_client_args(["--port", "8001", "--project", "p", "--name", "n"])
    @test spaced.port == 8001
    @test spaced.project == "p"
    @test spaced.name == "n"
    @test isnothing(spaced.code)

    joined = REPLicant._parse_client_args(["--project=/tmp/x", "--name=lbl", "--eval", "1"])
    @test joined.project == "/tmp/x"
    @test joined.name == "lbl"
    @test joined.code == "1"

    @test_throws Exception REPLicant._parse_client_args(["--port=abc"])
    @test_throws Exception REPLicant._parse_client_args(["--port"])
    @test_throws Exception REPLicant._parse_client_args(["--bogus"])
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
