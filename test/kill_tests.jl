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

    # A real child process: alive before the signal, gone after. A Julia
    # subprocess sleeps, so the test does not depend on a platform `sleep` binary.
    proc = run(`$(Base.julia_cmd()) --startup-file=no -e "sleep(30)"`; wait = false)
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
            REPLicant._write_registry_entry(9001, "/work/a"; token = "", name = "alpha")
            REPLicant._write_registry_entry(9002, "/work/b"; token = "", name = "beta")

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

@testitem "kill_target_skips_dead_entry_beside_live_server" tags = [:kill] setup = [Utilities] begin
    import REPLicant
    import Sockets

    # A server killed without cleanup leaves its entry. It must not make `kill` or
    # `restart` ambiguous next to the one server still running in the project.
    Utilities.withserver() do server, mod, port
        dead, listener = Sockets.listenany(0)
        close(listener)
        REPLicant._write_registry_entry(dead, server.project; token = "")
        @test REPLicant._kill_target(-1, server.project, "").port == port
    end
end

@testitem "kill_target_keeps_dead_entry_of_callers_project" tags = [:kill] setup = [Utilities] begin
    import REPLicant
    import Sockets

    # Dead entries drop out only among the caller's own candidates. A dead server
    # for a subproject must not hand `kill` to the live server of the parent.
    Utilities.withserver() do server, mod, port
        sub = mkpath(joinpath(server.project, "docs"))
        dead, listener = Sockets.listenany(0)
        close(listener)
        REPLicant._write_registry_entry(dead, sub; token = "")
        @test REPLicant._kill_target(-1, sub, "").port == Int(dead)
    end
end

@testitem "kill_spares_reused_pid" tags = [:kill] begin
    import REPLicant
    import Sockets

    # A server that died without cleanup: its port is closed and the OS handed its
    # pid to an unrelated process.
    proc = run(`$(Base.julia_cmd()) --startup-file=no -e "sleep(30)"`; wait = false)
    try
        port, listener = Sockets.listenany(0)
        close(listener)
        mktempdir() do registry
            withenv("REPLICANT_DIR" => registry) do
                path = REPLicant._write_registry_entry(port, "/work/a"; token = "")
                write(path, replace(read(path, String), r"pid=\d+" => "pid=$(getpid(proc))"))

                out = IOBuffer()
                @test REPLicant._kill_server(["--port=$port"]; out) == 0
                @test contains(String(take!(out)), "already gone")
                @test !isfile(path)
            end
        end
        sleep(0.5)
        @test process_running(proc)
    finally
        kill(proc, Base.SIGKILL)
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

@testitem "kill_shuts_down_server_without_a_signal" tags = [:kill] setup = [Utilities] begin
    import REPLicant

    # A SIGTERM makes Julia print a backtrace to the server's terminal and run its
    # exit hooks from wherever the main thread was, which can hang inside libuv.
    mktempdir() do registry
        mktempdir() do work
            log = joinpath(work, "server.log")
            entry_path = Utilities.spawn_server(registry, work; err = log) do port, pid
                out = IOBuffer()
                withenv("REPLICANT_DIR" => registry) do
                    @test REPLicant._kill_server(["--port=$port"]; out) == 0
                end
                @test contains(String(take!(out)), "shut down")
                @test !REPLicant._process_alive(pid)
            end
            @test !isfile(entry_path)
            @test !contains(read(log, String), "signal")
        end
    end
end

@testitem "kill_reports_surviving_process" tags = [:kill] begin
    import REPLicant
    import Sockets

    # libuv's SIGTERM always terminates a Windows process, so only POSIX can survive it.
    if Sys.iswindows()
        @test true skip = true
    else
        # A process that ignores SIGTERM, standing in for a server that cannot act on
        # it. Julia's own signal thread overrides `SIG_IGN`, so a shell traps it.
        proc = run(`sh -c 'trap "" TERM; sleep 60'`; wait = false)
        port, listener = Sockets.listenany(0)
        try
            mktempdir() do registry
                withenv("REPLICANT_DIR" => registry) do
                    path = REPLicant._write_registry_entry(port, "/work/a"; token = "")
                    write(path, replace(read(path, String), r"pid=\d+" => "pid=$(getpid(proc))"))

                    out, err = IOBuffer(), IOBuffer()
                    @test REPLicant._kill_server(["--port=$port"]; out, err) == 1
                    @test contains(String(take!(err)), "--force")
                    @test isfile(path)
                    @test process_running(proc)
                end
            end
        finally
            close(listener)
            kill(proc, Base.SIGKILL)
        end
    end
end
