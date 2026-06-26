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
            _parse_args(sample)
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
                            frame = _read_frame(sock, REQUEST_TYPES)
                            if !isnothing(frame) && frame.type == REQUEST_PING
                                _write_frame(sock, RESPONSE_PONG, "")
                            else
                                _write_frame(sock, RESPONSE_OK, "2")
                            end
                        catch  # dendro-ignore: empty_catch -- throwaway acceptor, per-connection errors are irrelevant to precompilation
                        finally
                            close(sock)
                        end
                    end
                catch  # dendro-ignore: empty_catch -- acceptor loop ends when the listener closes
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
        catch  # dendro-ignore: empty_catch -- guard so a sandbox without loopback never fails precompilation
        end
    end
end
