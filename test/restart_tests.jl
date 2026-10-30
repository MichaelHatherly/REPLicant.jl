@testitem "restart_reexecs_server_in_place" tags = [:restart] setup = [Utilities] begin
    import REPLicant

    # Re-exec replaces the process image, so the restarted server keeps its pid but
    # binds a fresh port and starts from an empty session.
    @static if !Sys.iswindows()
        mktempdir() do registry
            mktempdir() do work
                withenv("REPLICANT_DIR" => registry) do
                    Utilities.spawn_server(registry, work) do port, pid
                        @test contains(Utilities.request(port, "marker = 42"), "42")

                        out = IOBuffer()
                        err = IOBuffer()
                        @test REPLicant.cli(["restart", "--port=$port"]; out, err) == 0
                        @test String(take!(err)) == ""

                        entry = only(REPLicant._read_entries())
                        @test entry.pid == string(pid)
                        @test entry.port != port
                        @test contains(String(take!(out)), "port $(entry.port)")
                        @test contains(Utilities.request(entry.port, "isdefined(Main, :marker)"), "false")
                    end
                end
            end
        end
    end
end

@testitem "restart_refused_on_windows" tags = [:restart] setup = [Utilities] begin
    import REPLicant

    # Windows has no exec, so the server refuses rather than dropping its console.
    @static if Sys.iswindows()
        Utilities.withserver() do server, mod, port
            frame = Utilities.requestframe(port, REPLicant.REQUEST_RESTART, "")
            @test frame.type == REPLicant.RESPONSE_ERR
            @test contains(frame.body, "macOS and Linux only")
        end
    end
end
