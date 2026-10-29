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
                token = _new_token()
                acceptor = @async try
                    while true
                        sock = Sockets.accept(listener)
                        @async try
                            frame = _read_request(sock, token, READ_TIMEOUT_SECONDS)
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
                    _write_registry_entry(port, dir; token)
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

# `cli` specializes on its streams, and the client's stdout and stderr are each a
# terminal, a pipe, or a file depending on how it is run. The workload above only
# reaches IOBuffer, so compile every pairing the entry point can see. `cli` reaches
# `_send` by runtime dispatch over its optional flags; cover the call with no flags.
precompile(cli, ())
for out in (Base.TTY, Base.PipeEndpoint, IOStream), err in (Base.TTY, Base.PipeEndpoint, IOStream)
    precompile(Core.kwcall, (NamedTuple{(:out, :err), Tuple{out, err}}, typeof(cli), Vector{String}))
    send_kwargs = NamedTuple{
        (:out, :err, :timeout_seconds, :cwd, :mod, :head_lines, :tail_lines),
        Tuple{out, err, Nothing, String, String, Nothing, Nothing},
    }
    precompile(Core.kwcall, (send_kwargs, typeof(_send), Int, String))
end
