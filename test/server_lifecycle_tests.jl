@testitem "server_starts_and_stops" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        @test server isa REPLicant.Server
        @test server.task isa Task
        @test !istaskdone(server.task)
    end
end

@testitem "binds_ephemeral_port" setup = [Utilities] tags = [:server_lifecycle] begin
    # An OS-assigned port sits in the ephemeral range (32768+ on Linux, 49152+ on
    # macOS and Windows), clear of the low ports dev servers and health checkers use.
    Utilities.withserver() do server, mod, port
        @test port >= 32768
    end
end

@testitem "registry_entry_creation" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    entry_path = Ref{String}()

    Utilities.withserver() do server, mod, port
        registry = ENV["REPLICANT_DIR"]
        entry = joinpath(registry, string(port))
        entry_path[] = entry
        @test isfile(entry)

        fields = REPLicant._parse_registry_entry(entry)
        @test parse(Int, fields["port"]) == port
        @test fields["project"] == REPLicant._project_root()
        @test haskey(fields, "pid")
        @test haskey(fields, "started")
    end

    # The entry is removed on shutdown.
    @test !isfile(entry_path[])
end

@testitem "server_cleanup_on_error" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    mktempdir() do tmp
        registry = mktempdir()
        withenv("REPLICANT_DIR" => registry) do
            cd(tmp) do
                server = REPLicant.Server()
                port = take!(server.channel)
                entry = joinpath(registry, string(port))
                @test isfile(entry)

                # Simulate abnormal termination.
                schedule(server.task, InterruptException(); error = true)
                sleep(0.3)

                @test !isfile(entry)
            end
        end
    end
end

@testitem "multiple_servers_per_project" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    # Several servers in one project coexist; each registers under its own port.
    Utilities.withproject() do start, registry
        _, p1 = start()
        _, p2 = start()
        @test p1 != p2
        @test isfile(joinpath(registry, string(p1)))
        @test isfile(joinpath(registry, string(p2)))
    end
end

@testitem "label_sets_registry_name" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    Utilities.withproject() do start, registry
        server, port = start()
        @test REPLicant.label!(server, "tests") == "tests"
        fields = REPLicant._parse_registry_entry(joinpath(registry, string(port)))
        @test fields["name"] == "tests"
    end
end

@testitem "label_rejects_duplicate_in_project" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.withproject() do start, registry
        first, _ = start()
        @test REPLicant.label!(first, "tests") == "tests"
        second, _ = start()
        # The label is taken by a live server in the same project.
        @test_throws Exception REPLicant.label!(second, "tests")
        # A distinct label is fine.
        @test REPLicant.label!(second, "docs") == "docs"
    end
end

@testitem "close_keeps_capturing_an_eval_that_outlives_the_interrupt" tags = [:server_lifecycle] setup = [Utilities] begin
    import REPLicant

    # The eval swallows the shutdown interrupt and carries on printing. Its output
    # must still reach its client, so the server keeps its hold on routing until
    # the worker finishes, and gives it up after.
    Utilities.withserver() do server, mod, port
        code = "try sleep(600) catch end; sleep(2); println(\"after interrupt\"); 1"
        running = @async Utilities.request(port, code)
        @test timedwait(() -> !isnothing(server.busy_since), 10.0) === :ok
        close(server)
        sleep(0.5)
        @test haskey(REPLicant.SERVERS, server)
        @test timedwait(() -> istaskdone(running), 10.0) === :ok
        @test contains(fetch(running), "after interrupt")
        @test timedwait(() -> istaskdone(server.task), 10.0) === :ok
        @test !haskey(REPLicant.SERVERS, server)
    end
end

@testitem "closed_servers_leave_no_exit_hooks" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    # A warm session that runs this suite starts and closes many servers. Each one
    # left an exit hook holding it, which at exit removed whatever entry by then sat
    # on its old port, even another process's.
    Utilities.withproject() do start, registry
        server, _ = start()
        Utilities.wait_closed(server)
        hooks = length(Base.atexit_hooks)
        for _ in 1:3
            server, _ = start()
            Utilities.wait_closed(server)
        end
        @test length(Base.atexit_hooks) == hooks
    end
end

@testitem "label_cleared_beside_unlabeled_server" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.withproject() do start, registry
        labeled, port = start()
        REPLicant.label!(labeled, "tests")
        start()
        # An empty label clears the name; unlabeled servers do not hold "".
        @test REPLicant.label!(labeled, "") == ""
        @test !contains(read(joinpath(registry, string(port)), String), "name=")
    end
end

@testitem "label_rejects_newline" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    Utilities.withproject() do start, registry
        server, _ = start()
        @test_throws Exception REPLicant.label!(server, "a\nb")
    end
end

@testitem "label_without_handle_labels_session_server" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            _, port = start(; save = true)
            start()
            @test REPLicant.label!("tests") == "tests"
            fields = REPLicant._parse_registry_entry(joinpath(registry, string(port)))
            @test fields["name"] == "tests"
        end
    end
end

@testitem "test_servers_stay_out_of_the_slot" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    # Unsaved servers, as test suites start them, never displace the session's own.
    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            session, _ = start(; save = true)
            other, _ = start()
            @test REPLicant.server() === session
            Utilities.wait_closed(other)
            @test REPLicant.server() === session
        end
    end
end

@testitem "saved_server_builds_the_rpc_client_image" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    # A saved server runs `julia +rpc help` once it registers, so the channel's client
    # image is built before the next client call needs it. Unsaved servers, as test
    # suites start them, leave it alone. A stand-in `julia` on `PATH` records the call.
    # It is a shell script, and Windows spawns only executables, so it runs elsewhere.
    mktempdir() do bin
        calls = joinpath(bin, "calls")
        julia = joinpath(bin, "julia")
        write(julia, "#!/bin/sh\necho \"\$@\" >> '$calls'\n")
        chmod(julia, 0o755)
        withenv("PATH" => bin * ":" * ENV["PATH"]) do
            Utilities.without_current_server() do
                Utilities.withproject() do start, registry
                    start()
                    start(; save = true)
                    @test timedwait(() -> isfile(calls), 10) === :ok skip = Sys.iswindows()
                    sleep(0.5)
                    @test strip.(readlines(calls)) == ["+rpc help"] skip = Sys.iswindows()
                end
            end
        end
    end
end

@testitem "second_saved_server_replaces_first" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            start(; save = true)
            replacement, _ = start(; save = true)
            @test REPLicant.server() === replacement
        end
    end
end

@testitem "label_without_handle_labels_unsaved_server" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    # With no saved server running, the latest server is the one labeled.
    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            start()
            _, port = start()
            @test REPLicant.label!("tests") == "tests"
            fields = REPLicant._parse_registry_entry(joinpath(registry, string(port)))
            @test fields["name"] == "tests"
        end
    end
end

@testitem "server_handle_not_saved_by_default" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        @test server.save == false
        # A handle is only handed back via `server()` when saved.
        @test REPLicant.server() !== server
    end
end

@testitem "server_handle_saved_when_requested" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.without_current_server() do
        Utilities.withproject() do start, registry
            server, _ = start(; save = true)
            @test REPLicant.server() === server

            Utilities.wait_closed(server)
            # A stopped server is no longer handed back.
            @test REPLicant.server() === nothing
        end
    end
end

@testitem "show_reports_server_state" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    handle = Ref{REPLicant.Server}()
    Utilities.withserver() do server, mod, port
        handle[] = server
        text = sprint(show, MIME("text/plain"), server)
        @test contains(text, "running")
        @test contains(text, string(port))
        @test contains(text, "max_connections")
    end
    # withserver closes and waits the task before returning.
    @test contains(sprint(show, MIME("text/plain"), handle[]), "stopped")
end

@testitem "verbose_logs_lifecycle" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant
    import Logging
    import Test

    mktempdir() do tmp
        registry = mktempdir()
        withenv("REPLICANT_DIR" => registry) do
            cd(tmp) do
                logger = Test.TestLogger()
                Logging.with_logger(logger) do
                    server = REPLicant.Server(; verbose = true)
                    take!(server.channel)
                    Utilities.wait_closed(server)
                end
                @test any(r -> contains(r.message, "REPLicant listening"), logger.logs)
            end
        end
    end
end

@testitem "quiet_by_default" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant
    import Logging
    import Test

    mktempdir() do tmp
        registry = mktempdir()
        withenv("REPLICANT_DIR" => registry) do
            cd(tmp) do
                logger = Test.TestLogger()
                Logging.with_logger(logger) do
                    server = REPLicant.Server()
                    take!(server.channel)
                    Utilities.wait_closed(server)
                end
                @test !any(r -> contains(r.message, "REPLicant listening"), logger.logs)
            end
        end
    end
end

@testitem "label_requires_running_server" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    Utilities.without_current_server() do
        @test_throws Exception REPLicant.label!("orphan")
    end
end

@testitem "server_close_twice" tags = [:server_lifecycle] setup = [Utilities] begin
    import REPLicant

    server = Utilities.withproject() do start, registry
        server, _ = start()
        Utilities.wait_closed(server)
        server
    end
    @test close(server) === nothing
end

@testitem "close_interrupts_running_eval" tags = [:server_lifecycle] setup = [Utilities] begin
    import REPLicant

    # A close must not wait out the running eval, nor run the ones queued behind it.
    Utilities.withserver() do server, mod, port
        entry = REPLicant._registry_entry_path(port)
        running = @async Utilities.request(port, "sleep(600)")
        deadline = time() + 30
        while isempty(something(REPLicant._ping_status(port), "")) && time() < deadline
            sleep(0.05)
        end
        queued = @async Utilities.request(port, "global queued_ran = true")
        sleep(0.5)

        close(server)
        @test timedwait(() -> istaskdone(server.task), 10) === :ok
        @test !isfile(entry)
        @test contains(fetch(running), "InterruptException")
        @test contains(fetch(queued), "shutting down")
        @test !isdefined(mod, :queued_ran)
    end
end
