#
# Precompilation.
#
# The workload starts a real server and runs the client's commands against it, so
# what both sides run on a first request is compiled into the package image.
#
# Precompilation refuses evaluation that defines anything outside the package, so
# the workload's code creates no globals and names no session module. Nor does it run
# a script file: a file included while precompiling becomes a dependency of the image.

# One server's life, with the client's commands run against it.
function _workload_session(dir::String)
    # The client's entry point as `bin/client.jl` calls it. Run before the server
    # starts, since the server swaps the process's streams for its routers.
    _with_args(cli, ["help"])
    # Started the way `startup.jl` and `julia +rpc start` start one, from the top
    # level, where each call is dispatched at runtime. Inlined here, the entries
    # those calls need would never be compiled.
    server = Base.invokelatest(Server; save = true)::Server
    try
        port = take!(Base.invokelatest(getproperty, server, :channel)::Channel{Int})
        for args in _workload_requests(port, dir)
            cli(args; out = stdout, err = stderr)
        end
        _workload_footer()
    finally
        close(server)
        try
            wait(server.task)
        catch  # dendro-ignore: empty_catch -- close schedules the InterruptException wait re-raises
        end
    end
    # The exit hook runs only after the image is written, so call it here. With the
    # server closed it has nothing to clean up.
    _exit_cleanup()
    _workload_kill()
    return nothing
end

# Paint the status row into a footer of its own, so the process's footer is never
# enabled and no painting task outlives the workload.
function _workload_footer()
    footer = Footers.Footer(IOBuffer())
    Footers.set!(:status, _status_row, footer)
    footer.enabled = true
    Footers.repaint!(footer)
    Footers.disable!(footer)
    footer!(false)
    return nothing
end

# Put back the process-global state the workload's server leaves set, since the
# image a fresh process loads carries whatever it holds.
function _reset_workload_state!()
    EXIT_HOOKED[] = false
    ACTIVITY_CAPTURE_REQUESTED[] = false
    empty!(ACTIVITY)
    REAL_OUT[] = devnull
    REAL_ERR[] = devnull
    reset(Footers.FOOTER.wake)
    return nothing
end

# Run by the package and again by each extension, since an extension's methods
# invalidate the package's compiled callers when it loads.
function _run_workload()
    try
        _workload(_workload_session)
    catch  # dendro-ignore: empty_catch -- guard so a sandbox without loopback never fails precompilation
    finally
        _reset_workload_state!()
    end
    return nothing
end

PrecompileTools.@compile_workload _run_workload()

# libuv calls these on every connection, and before Julia 1.12 the workload's
# inference capture misses them, so each process would compile them on first use.
@static if VERSION < v"1.12"
    precompile(Sockets.uv_connectcb, (Ptr{Cvoid}, Cint))
    precompile(Sockets.uv_connectioncb, (Ptr{Cvoid}, Cint))
    precompile(Base.uvfinalize, (Sockets.TCPSocket,))
    precompile(Base.uvfinalize, (Sockets.TCPServer,))
end
