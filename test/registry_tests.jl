@testitem "registry_skips_inflight_temp_files" tags = [:registry] begin
    import REPLicant

    mktempdir() do registry
        withenv("REPLICANT_DIR" => registry) do
            REPLicant._write_registry_entry(9001, "/work/a"; token = "")
            # An atomic write in progress leaves its temp file beside the entries.
            cp(joinpath(registry, "9001"), joinpath(registry, "9001.tmp.123"))

            @test [entry.port for entry in REPLicant._read_entries()] == [9001]
        end
    end
end

@testitem "registry_skips_entries_removed_mid_scan" tags = [:registry] begin
    import REPLicant

    mktempdir() do registry
        withenv("REPLICANT_DIR" => registry) do
            REPLicant._write_registry_entry(9001, "/work/a"; token = "")
            # Listed by `readdir`, gone by the time it is opened.
            symlink(joinpath(registry, "removed"), joinpath(registry, "9002"))

            @test [entry.port for entry in REPLicant._read_entries()] == [9001]
            @test REPLicant._label_conflict("/work/a", "x", 0) === nothing
            @test REPLicant._prune_dead_entries("/work/a") === nothing
            @test REPLicant._entry_token(9002) == ""
        end
    end
end

@testitem "registry_keeps_unresponsive_server" tags = [:registry] begin
    import REPLicant
    import Sockets

    mktempdir() do registry
        withenv("REPLICANT_DIR" => registry) do
            # A listener nobody accepts on: the kernel completes the handshake but no
            # pong ever comes, like a server wedged on its only thread.
            port, listener = Sockets.listenany(0)
            try
                path = REPLicant._write_registry_entry(port, "/work/a"; token = "")

                @test isempty(REPLicant._live_entries())
                @test isfile(path)

                out = IOBuffer()
                REPLicant._list_servers(out)
                @test contains(String(take!(out)), "unresponsive")
                @test isfile(path)

                REPLicant._prune_dead_entries("/work/a")
                @test isfile(path)
            finally
                close(listener)
            end
        end
    end
end

@testitem "registry_prunes_closed_port" tags = [:registry] begin
    import REPLicant
    import Sockets

    mktempdir() do registry
        withenv("REPLICANT_DIR" => registry) do
            port, listener = Sockets.listenany(0)
            close(listener)
            path = REPLicant._write_registry_entry(port, "/work/a"; token = "")

            @test isempty(REPLicant._live_entries())
            @test !isfile(path)
        end
    end
end
