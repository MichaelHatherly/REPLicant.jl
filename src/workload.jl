#
# Precompile workload pieces both builds share.
#
# The streams the client writes to never reach specialized code (see `Output`), so
# one session over a file covers terminals and pipes too.

# Run `session(dir)` in a scratch directory with its own registry and its output
# sent to a file.
function _workload(session)
    mktempdir() do dir
        withenv("REPLICANT_DIR" => joinpath(dir, "registry")) do
            cd(dir) do
                mktemp() do _, file
                    redirect_stdio(() -> session(dir); stdout = file, stderr = file)
                end
            end
        end
    end
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

# `kill` aimed at a registered server whose process is gone, which it reports and
# unregisters without signalling anything. The pid is past any the OS hands out.
function _workload_kill()
    listener = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(listener)[2])
    close(listener)
    path = _write_registry_entry(port, pwd(); token = "", started = "")
    write(path, replace(read(path, String), r"pid=\d+" => "pid=$(typemax(Int32))"))
    cli(["kill", "--port=$port"]; out = stdout, err = stderr)
    return nothing
end
