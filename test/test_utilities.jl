@testmodule Utilities begin
    import Logging
    import REPLicant
    import Sockets
    import Test

    # Send an eval frame without waiting for the response. Used to hold a
    # connection slot open.
    function sendframe(sock, code)
        REPLicant._write_frame(sock, REPLicant.REQUEST_EVAL, code)
        return sock
    end

    # Read one response frame: `(; type, body)`, or `nothing` on a bare disconnect.
    readframe(sock) = REPLicant._read_frame(sock, REPLicant.RESPONSE_TYPES)

    # The body of the response (empty when the peer sent nothing).
    function readresp(sock)
        frame = readframe(sock)
        return isnothing(frame) ? "" : frame.body
    end

    # Frame an eval request the way the CLI does and return the response body.
    function request(port, code)
        sock = Sockets.connect(Sockets.localhost, port)
        try
            sendframe(sock, code)
            return readresp(sock)
        finally
            close(sock)
        end
    end

    # Send an arbitrary typed frame and return the full response frame.
    function requestframe(port, type, body)
        sock = Sockets.connect(Sockets.localhost, port)
        try
            REPLicant._write_frame(sock, type, body)
            return readframe(sock)
        finally
            close(sock)
        end
    end

    # Close a server and wait for its task to finish, so a test can inspect
    # post-shutdown state (the registry entry removed, the handle reporting
    # stopped). `close` schedules an InterruptException into the task that `wait`
    # re-raises; swallowing it is the expected path.
    function wait_closed(server)
        close(server)
        try
            wait(server.task)
        catch  # dendro-ignore: empty_catch -- close schedules the InterruptException wait re-raises
        end
        return nothing
    end

    # Start a server in an isolated temporary project with its own registry
    # directory, so tests neither see each other's servers nor touch the real
    # registry.
    function withserver(
            func;
            max_connections::Int = 100,
            read_timeout_seconds::Float64 = 30.0,
        )
        mod = Module()
        mktempdir() do tmp
            registry = mktempdir()
            withenv("REPLICANT_DIR" => registry) do
                cd(tmp) do
                    logger = Test.TestLogger()
                    Logging.with_logger(logger) do
                        server =
                            REPLicant.Server(mod; max_connections, read_timeout_seconds)
                        port = take!(server.channel)
                        @info "REPLicant server started" port max_connections
                        entry = joinpath(registry, string(port))
                        @assert isfile(entry)
                        try
                            func(server, mod, port)
                        finally
                            # Wait for shutdown so the registry entry is gone
                            # before the test inspects it.
                            wait_closed(server)
                        end
                    end
                end
            end
        end
    end

    # Launch a REPLicant server in a separate Julia process registered in
    # `registry`, rooted at `work`. Waits for its registry entry, then runs
    # `func(port, pid)` against the live process. The subprocess is killed on exit;
    # returns the entry path so a test can assert it was cleaned up. Used by kill
    # tests, which must target a process other than the test runner.
    function spawn_server(func, registry, work)
        script = "using REPLicant; s = REPLicant.Server(); take!(s.channel); wait(s.task)"
        project = pkgdir(REPLicant)
        env = copy(ENV)
        env["REPLICANT_DIR"] = registry
        cmd = setenv(
            `$(Base.julia_cmd()) --project=$project --startup-file=no -e $script`,
            env;
            dir = work,
        )
        proc = run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
        return try
            entry_path = _wait_for_entry(registry)
            fields = REPLicant._parse_registry_entry(entry_path)
            func(parse(Int, fields["port"]), parse(Int, fields["pid"]))
            entry_path
        finally
            process_running(proc) && kill(proc, Base.SIGKILL)
        end
    end

    function _wait_for_entry(registry; timeout = 60)
        deadline = time() + timeout
        while time() < deadline
            files = filter(f -> isfile(joinpath(registry, f)), readdir(registry))
            isempty(files) || return joinpath(registry, first(files))
            sleep(0.1)
        end
        return error("server did not register within $(timeout)s")
    end

    # Run `func(start, registry)` inside an isolated project and registry, where
    # `start()` launches another server in that same project and returns
    # `(server, port)`. Lets a test stand up several servers in one project to
    # exercise multi-server selection and labeling. Any server still open is
    # closed on exit.
    function withproject(func)
        mktempdir() do tmp
            registry = mktempdir()
            withenv("REPLICANT_DIR" => registry) do
                cd(tmp) do
                    servers = REPLicant.Server[]
                    start = function ()
                        server = REPLicant.Server(Module())
                        push!(servers, server)
                        return server, take!(server.channel)
                    end
                    logger = Test.TestLogger()
                    Logging.with_logger(logger) do
                        try
                            func(start, registry)
                        finally
                            for server in servers
                                wait_closed(server)
                            end
                        end
                    end
                end
            end
        end
    end
end
