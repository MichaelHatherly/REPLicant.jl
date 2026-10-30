#
# Precompilation.
#
# The workload starts a real server and runs the client's commands against it, so
# what both sides run on a first request is compiled into the package image. The
# streams either side writes to never reach specialized code (see `Output`), so one
# session over a file covers terminals and pipes too.
#
# Precompilation refuses evaluation that defines anything outside the package, so
# the workload's code creates no globals and names no session module. Nor does it run
# a script file: a file included while precompiling becomes a dependency of the image.

function _workload()
    mktempdir() do dir
        withenv("REPLICANT_DIR" => joinpath(dir, "registry")) do
            cd(dir) do
                mktemp() do _, file
                    redirect_stdio(() -> _workload_session(dir); stdout = file, stderr = file)
                end
            end
        end
    end
    return nothing
end

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

# Call `f()` with `ARGS` set to `args`, dispatched at runtime as a script's top level
# calls it.
function _with_args(f, args::Vector{String})
    saved = copy(ARGS)
    append!(empty!(ARGS), args)
    try
        return Base.invokelatest(f)
    finally
        append!(empty!(ARGS), saved)
    end
end

function _workload_requests(port::Int, dir::String)
    p = "--port=$port"
    return [
        ["ls"],
        [p, "-e", "1 + 1"],
        [p, "-e", "1 + 1;"],
        [p, "-e", "println(\"output\"); [1, 2]"],
        [p, "-e", "@info \"note\" x = 1"],
        [p, "-e", "display([1 2; 3 4])"],
        [p, "-e", "error(\"boom\")"],
        [p, "-e", "1 +"],
        [p, "-e", "?sin"],
        [p, "--dir=$dir", "-e", "pwd()"],
        ["log", p],
        ["log", "1", p],
        ["log", p, "--since=1"],
        ["interrupt", p],
        ["reset", p, "--module=workload"],
        ["--name=workload", "-e", "1"],
        _workload_option_mixes(p)...,
    ]
end

# An eval under every mix of `--timeout`, `--head-lines`, and `--tail-lines`. Each
# mix hands `_send` its own keyword type, which Julia 1.10 compiles separately
# despite `@nospecialize`.
function _workload_option_mixes(p::String)
    timeouts = (String[], ["--timeout=30"])
    heads = (String[], ["--head-lines=1"])
    tails = (String[], ["--tail-lines=1"])
    return [[p; t; h; l; "-e"; "for i in 1:3; println(i); end"] for t in timeouts, h in heads, l in tails]
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

# `kill` aimed at a registered server whose process is gone, which it reports and
# unregisters without signalling anything. The pid is past any the OS hands out.
function _workload_kill()
    listener = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(listener)[2])
    close(listener)
    path = _write_registry_entry(port, pwd(); token = "")
    write(path, replace(read(path, String), r"pid=\d+" => "pid=$(typemax(Int32))"))
    cli(["kill", "--port=$port"]; out = stdout, err = stderr)
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
        _workload()
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
