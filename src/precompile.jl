#
# Precompilation.
#

PrecompileTools.@setup_workload begin
    arg_samples = [
        ["--port=8000", "-e", "1 + 1"],
        ["--project", "/tmp", "--name=demo"],
        ["--name=demo", "-e", "x"],
    ]
    PrecompileTools.@compile_workload begin
        for sample in arg_samples
            _parse_client_args(sample)
        end
        # Exercise the registry and socket paths against a throwaway loopback
        # server so the framing, ping, and selection code specialize. Guarded so
        # a sandbox without loopback never fails precompilation.
        try
            mktempdir() do dir
                listener = Sockets.listen(Sockets.localhost, 0)
                port = Int(Sockets.getsockname(listener)[2])
                acceptor = @async try
                    while true
                        sock = Sockets.accept(listener)
                        @async try
                            _read_request(sock)
                            write(sock, "ok")
                            flush(sock)
                        catch
                        finally
                            close(sock)
                        end
                    end
                catch
                end
                withenv("REPLICANT_DIR" => dir) do
                    _write_registry_entry(port, dir)
                    _live_entries()
                    _resolve_port(0, dir, "")
                    _send(port, "1 + 1"; out = IOBuffer())
                    _list_servers(IOBuffer())
                end
                close(listener)
            end
        catch
        end
    end
end
