@testitem "kill_args_parsing" tags = [:kill] begin
    import REPLicant

    bare = REPLicant._parse_args(["--port=8000"])
    @test bare.port == 8000
    @test bare.force == false

    spaced = REPLicant._parse_args(["--name", "n", "--project", "p", "--force"])
    @test spaced.name == "n"
    @test spaced.project == "p"
    @test spaced.force == true

    @test REPLicant._parse_args(["-f"]).force == true
    @test_throws Exception REPLicant._parse_args(["--bogus"])
end

@testitem "process_liveness_and_signal" tags = [:kill] begin
    import REPLicant

    # A real child process: alive before the signal, gone after.
    proc = run(`sleep 30`; wait = false)
    pid = Base.process_running(proc) ? getpid(proc) : error("child did not start")
    @test REPLicant._process_alive(pid)

    @test REPLicant._signal_process(pid, REPLicant.SIGKILL)
    wait(proc)
    @test !REPLicant._process_alive(pid)

    # Signalling a pid that is already gone reports not-delivered, never throws.
    @test REPLicant._signal_process(pid, REPLicant.SIGTERM) == false
end

@testitem "kill_target_selection" tags = [:kill] begin
    import REPLicant

    # Raw registry resolution: no ping, so a wedged server still resolves. Write
    # entries with arbitrary pids and assert the cascade picks the right one.
    mktempdir() do registry
        withenv("REPLICANT_DIR" => registry) do
            REPLicant._write_registry_entry(9001, "/work/a"; name = "alpha")
            REPLicant._write_registry_entry(9002, "/work/b"; name = "beta")

            @test REPLicant._kill_target(9001, "", "").port == 9001
            @test REPLicant._kill_target(-1, "", "beta").port == 9002

            # An unregistered port has nothing to kill.
            @test_throws Exception REPLicant._kill_target(9999, "", "")
            # Two servers, no selector: ambiguous.
            @test_throws Exception REPLicant._kill_target(-1, "", "")
            # Unknown name.
            @test_throws Exception REPLicant._kill_target(-1, "", "missing")
        end
    end
end

@testitem "kill_terminates_wedged_server" tags = [:kill] setup = [Utilities] begin
    import REPLicant
    import Sockets

    mktempdir() do registry
        mktempdir() do work
            entry_path = Utilities.spawn_server(registry, work) do port, pid
                # Wedge the worker on a non-returning eval: fire the frame and do
                # not wait for a response that will never come.
                wedge = Sockets.connect(Sockets.localhost, port)
                REPLicant._write_frame(wedge, REPLicant.REQUEST_EVAL, "while true; end")
                sleep(0.5)

                out = IOBuffer()
                withenv("REPLICANT_DIR" => registry) do
                    # Kill resolves and terminates without needing a pong.
                    @test REPLicant._kill_server(["--port=$port", "--force"]; out) == 0
                end
                @test contains(String(take!(out)), string(pid))

                # The process dies and its registry entry is removed.
                deadline = time() + 10
                while REPLicant._process_alive(pid) && time() < deadline
                    sleep(0.1)
                end
                @test !REPLicant._process_alive(pid)
                close(wedge)
            end
            @test !isfile(entry_path)
        end
    end
end
