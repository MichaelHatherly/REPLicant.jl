@testmodule Utilities begin
    import Logging
    import REPLicant
    import Sockets
    import Test

    # Write a length-prefixed request (byte-count line, then code bytes) without
    # waiting for the response. Used to hold a connection slot open.
    function sendframe(sock, code)
        bytes = Vector{UInt8}(codeunits(code))
        write(sock, "$(length(bytes))\n")
        write(sock, bytes)
        flush(sock)
        return sock
    end

    # Read a full response (until the server closes the connection).
    readresp(sock) = String(read(sock))

    # Frame a request the way the CLI does and return the full response.
    function request(port, code)
        sock = Sockets.connect(Sockets.localhost, port)
        try
            sendframe(sock, code)
            return readresp(sock)
        finally
            close(sock)
        end
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
                            close(server)
                            try
                                wait(server.task)
                            catch
                            end
                        end
                    end
                end
            end
        end
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
                                close(server)
                                try
                                    wait(server.task)
                                catch
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
