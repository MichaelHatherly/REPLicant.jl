#
# Precompilation of the client-only build.
#
# The build has no server, so the workload answers the client's requests from a
# loopback acceptor in this process, built from the protocol's own reader and writer.

function _client_workload_session(dir::String)
    _with_args(cli, ["help"])
    listener = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(listener)[2])
    token = _new_token()
    acceptor = @async _workload_acceptor(listener, token)
    try
        _write_registry_entry(port, dir; token, name = "workload", started = "")
        for args in _workload_requests(port, dir)
            cli(args; out = stdout, err = stderr)
        end
    finally
        close(listener)
        wait(acceptor)
    end
    _workload_kill()
    return nothing
end

# Answer pings with an idle pong and every other request with a fixed value.
function _workload_acceptor(listener::Sockets.TCPServer, token::String)
    while isopen(listener)
        sock = try
            Sockets.accept(listener)
        catch  # dendro-ignore: empty_catch -- the listener closing ends the loop
            break
        end
        try
            frame = _read_request(sock, token, READ_TIMEOUT_SECONDS)
            if !isnothing(frame) && frame.type == REQUEST_PING
                _write_frame(sock, RESPONSE_PONG, "")
            else
                _write_frame(sock, RESPONSE_OK, "1\n")
            end
        finally
            close(sock)
        end
    end
    return nothing
end

# The image keeps only the external code marked for it, and libuv reaches Base's
# socket callbacks by runtime dispatch. Mark what inference produces during `f`, the
# step PrecompileTools takes, without loading it and its dependencies on every call.
@static if VERSION >= v"1.12"
    function _precompile_inferred(f)
        ccall(:jl_tag_newly_inferred_enable, Cvoid, ())
        try
            f()
        finally
            ccall(:jl_tag_newly_inferred_disable, Cvoid, ())
        end
        return nothing
    end
else
    function _precompile_inferred(f)
        Core.Compiler.Timings.reset_timings()
        Core.Compiler.__set_measure_typeinf(true)
        try
            f()
        finally
            Core.Compiler.__set_measure_typeinf(false)
            Core.Compiler.Timings.close_current_timer()
        end
        foreach(_precompile_tree, Core.Compiler.Timings._timings[1].children)
        return nothing
    end

    function _precompile_tree(node)
        precompile(node.mi_info.mi.specTypes)
        foreach(_precompile_tree, node.children)
        return nothing
    end
end

function _run_client_workload()
    try
        _workload(_client_workload_session)
    catch  # dendro-ignore: empty_catch -- guard so a sandbox without loopback never fails precompilation
    end
    return nothing
end

ccall(:jl_generating_output, Cint, ()) == 1 && _precompile_inferred(_run_client_workload)

# Inference capture misses these before Julia 1.12 (see `precompile.jl`).
@static if VERSION < v"1.12"
    precompile(Sockets.uv_connectcb, (Ptr{Cvoid}, Cint))
    precompile(Base.uvfinalize, (Sockets.TCPSocket,))
end
