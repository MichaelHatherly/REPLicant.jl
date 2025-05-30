@testitem "server_starts_and_stops" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        # Test that server can be created and closed
        @test server isa REPLicant.Server
        @test server.task isa Task
        @test !istaskdone(server.task)
    end
    # After withserver, the server should be closed
    # We can't test istaskdone directly since server is out of scope
end

@testitem "port_file_creation" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    port_file_path = Ref{String}()

    Utilities.withserver() do server, mod, _
        # Find the port file
        justfile = REPLicant._find_just_file()
        @test !isnothing(justfile)
        port_file = joinpath(dirname(justfile), "REPLICANT_PORT")
        port_file_path[] = port_file
        @test isfile(port_file)

        # Read the port number
        port_str = read(port_file, String)
        port = parse(Int, strip(port_str))
        @test port >= 8000
    end

    # After withserver exits, port file should be cleaned up
    @test !isfile(port_file_path[])
end

@testitem "server_cleanup_on_error" setup = [Utilities] tags = [:server_lifecycle] begin
    import REPLicant

    # We need to create server manually to test error handling
    mktempdir() do tmp
        justfile = joinpath(tmp, "justfile")
        open(justfile, "w") do f
            write(f, "default:\n    echo 'Justfile created for REPLicant server'\n")
            flush(f)
        end
        cd(tmp) do
            server = REPLicant.Server()
            port = take!(server.channel)
            port_file = joinpath(tmp, "REPLICANT_PORT")
            @test isfile(port_file)

            # Simulate abnormal termination
            schedule(server.task, InterruptException(); error = true)
            sleep(0.2)

            # Port file should still be cleaned up
            @test !isfile(port_file)
        end
    end
end
