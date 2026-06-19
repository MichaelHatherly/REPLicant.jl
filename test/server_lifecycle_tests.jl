@testitem "server_starts_and_stops" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        @test server isa REPLicant.Server
        @test server.task isa Task
        @test !istaskdone(server.task)
        @test port >= 8000
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
        _, port = start()
        @test REPLicant.label!("tests") == "tests"
        fields = REPLicant._parse_registry_entry(joinpath(registry, string(port)))
        @test fields["name"] == "tests"
    end
end

@testitem "label_rejects_duplicate_in_project" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.withproject() do start, registry
        start()                                   # CURRENT_SERVER -> server 1
        @test REPLicant.label!("tests") == "tests"
        start()                                   # CURRENT_SERVER -> server 2
        # The label is taken by a live server in the same project.
        @test_throws Exception REPLicant.label!("tests")
        # A distinct label is fine.
        @test REPLicant.label!("docs") == "docs"
    end
end

@testitem "label_rejects_newline" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    Utilities.withproject() do start, registry
        start()
        @test_throws Exception REPLicant.label!("a\nb")
    end
end

@testitem "server_handle_not_saved_by_default" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        @test server.save == false
        # A handle is only handed back via `server()` when saved.
        @test REPLicant.server() === nothing
    end
end

@testitem "server_handle_saved_when_requested" setup = [Utilities] tags =
    [:server_lifecycle] begin
    import REPLicant

    mktempdir() do tmp
        registry = mktempdir()
        withenv("REPLICANT_DIR" => registry) do
            cd(tmp) do
                server = REPLicant.Server(; save = true)
                take!(server.channel)
                @test REPLicant.server() === server

                close(server)
                try
                    wait(server.task)
                catch
                end
                # A stopped server is no longer handed back.
                @test REPLicant.server() === nothing
            end
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

@testitem "verbose_logs_lifecycle" tags = [:server_lifecycle] begin
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
                    close(server)
                    try
                        wait(server.task)
                    catch
                    end
                end
                @test any(r -> contains(r.message, "REPLicant listening"), logger.logs)
            end
        end
    end
end

@testitem "quiet_by_default" tags = [:server_lifecycle] begin
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
                    close(server)
                    try
                        wait(server.task)
                    catch
                    end
                end
                @test !any(r -> contains(r.message, "REPLicant listening"), logger.logs)
            end
        end
    end
end

@testitem "label_requires_running_server" tags = [:server_lifecycle] begin
    import REPLicant

    old = REPLicant.CURRENT_SERVER[]
    REPLicant.CURRENT_SERVER[] = nothing
    try
        @test_throws Exception REPLicant.label!("orphan")
    finally
        REPLicant.CURRENT_SERVER[] = old
    end
end
