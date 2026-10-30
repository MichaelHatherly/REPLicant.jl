@testmodule Precompiled begin
    import REPLicant

    # A Julia command that loads REPLicant's package image. Coverage and allocation
    # tracking make Julia ignore package images, which would make every method look
    # compiled at runtime, so the test runner's own flags for those are dropped. Julia
    # 1.10 also turns package images off under coverage, and says so in `julia_cmd`.
    function julia_cmd()
        exec = filter(Base.julia_cmd().exec) do arg
            !startswith(arg, "--code-coverage") && !startswith(arg, "--track-allocation") &&
                arg != "--pkgimages=no"
        end
        return `$exec --startup-file=no --project=$(pkgdir(REPLicant))`
    end

    # The methods a process compiled at runtime. A process that compiled nothing leaves
    # no trace file.
    compiles(trace) = isfile(trace) ? readlines(trace) : String[]

    # Those that REPLicant owns or specializes on, and the socket callbacks libuv calls
    # on its connections.
    function owned_compiles(trace)
        return filter(line -> contains(line, "REPLicant") || contains(line, "Sockets"), compiles(trace))
    end

    # Base methods over Base types that a client compiles before Julia 1.12 whatever the
    # image holds: a `precompile` directive for them leaves them compiling at runtime.
    # The condition methods are those `connect` waits on and its callback notifies.
    BASE_ONLY = VERSION < v"1.12" ? [
            "precompile(Tuple{typeof(Base.lock), Base.GenericCondition{Base.Threads.SpinLock}})",
            "precompile(Tuple{typeof(Base.notify), Base.GenericCondition{Base.Threads.SpinLock}})",
            "precompile(Tuple{typeof(Base.unlock), Base.GenericCondition{Base.Threads.SpinLock}})",
            "precompile(Tuple{typeof(Base.repeat), Char, Int64})",
        ] : String[]

    # What a client process compiles just to start and load the client build, which no
    # workload of REPLicant's can reach.
    function client_baseline(julia, env, tmp)
        script = joinpath(tmp, "baseline.jl")
        client_mode = joinpath(pkgdir(REPLicant), "bin", "client-mode")
        write(script, "push!(LOAD_PATH, $(repr(client_mode)))\nusing REPLicant\nexit(0)\n")
        trace = joinpath(tmp, "baseline.txt")
        run(setenv(`$julia --trace-compile=$trace $script`, env))
        return compiles(trace)
    end

    # Start a server the way `julia +rpc start` does, after running `preamble` (which
    # loads an extension's trigger), and run each client command against it in its
    # own process. Returns what REPLicant compiled at runtime: per client command,
    # then for the server.
    function runtime_compiles(preamble::String)
        return mktempdir() do tmp
            registry = mkpath(joinpath(tmp, "registry"))
            work = mkpath(joinpath(tmp, "work"))
            write(joinpath(work, "script.jl"), "println(\"script ran\")\n:done\n")
            env = copy(ENV)
            env["REPLICANT_DIR"] = registry
            julia = julia_cmd()

            server_trace = joinpath(tmp, "server.txt")
            script = "$preamble using REPLicant; s = REPLicant.Server(save = true); take!(s.channel); wait(s.task)"
            server = setenv(`$julia --trace-compile=$server_trace -e $script`, env; dir = work)
            log = joinpath(tmp, "server.log")
            proc = run(pipeline(server; stdin = devnull, stdout = devnull, stderr = log); wait = false)
            clients = Pair{Vector{String}, Vector{String}}[]
            try
                port = wait_for_port(registry, proc)
                client = joinpath(pkgdir(REPLicant), "bin", "client.jl")
                baseline = client_baseline(julia, env, tmp)
                for (index, args) in enumerate(client_commands(port))
                    trace = joinpath(tmp, "client-$index.txt")
                    command = setenv(`$julia --trace-compile=$trace $client $args`, env; dir = work)
                    finished = finishes(pipeline(ignorestatus(command); stdin = devnull, stdout = devnull, stderr = devnull))
                    push!(clients, args => finished ? setdiff(compiles(trace), baseline, BASE_ONLY) : ["timed out"])
                end
                finishes(proc) || return (; clients, server = ["did not exit"; readlines(log)])
            finally
                process_running(proc) && kill(proc, Base.SIGKILL)
            end
            (; clients, server = owned_compiles(server_trace))
        end
    end

    # Whether a process exits within the deadline, killing it if not, so a hang
    # fails the test with what was stuck.
    finishes(command::Base.AbstractCmd) = finishes(run(command; wait = false))
    function finishes(proc::Base.Process)
        timedwait(() -> !process_running(proc), 300) === :ok && return true
        kill(proc, Base.SIGKILL)
        return false
    end

    function wait_for_port(registry, proc)
        deadline = time() + 300
        while time() < deadline && process_running(proc)
            entries = filter(f -> all(isdigit, f), readdir(registry))
            isempty(entries) || return only(entries)
            sleep(0.1)
        end
        return error("the server did not register")
    end

    # Every client command, ending with `kill`, which stops the server.
    function client_commands(port)
        p = "--port=$port"
        return [
            ["ls"],
            [p, "-e", "1 + 1"],
            [p, "-e", "println(\"hi\"); [1, 2]"],
            [p, "-e", "@info \"note\" x = 1"],
            [p, "-e", "error(\"boom\")"],
            [p, "-e", "1 +"],
            [p, "--module=m", "-e", "y = 2"],
            ["reset", p, "--module=m"],
            ["log", p],
            ["interrupt", p],
            [p, "script.jl"],
            [p, "--tail-lines=1", "-e", "for i in 1:3; println(i); end"],
            [p, "--timeout=60", "-e", "nothing"],
            [p, "-e", "?sin"],
            ["help"],
            ["kill", p],
        ]
    end

    # The client commands that compiled anything at runtime, or the server's own code.
    compiling_clients(result) = filter(pair -> !isempty(last(pair)), result.clients)
end

@testitem "precompiled_image_carries_no_workload_state" tags = [:precompile] setup = [Precompiled] begin
    # The workload runs a live server while the image is built, and every global it
    # leaves set is baked into the image a fresh process loads.
    script = """
    import REPLicant as R
    for (name, pristine) in [
            # A file the workload includes becomes a dependency of the image, which
            # is stale for good once the file is gone.
            "image fresh" => Base.isprecompiled(Base.PkgId(R)),
            "CURRENT_SERVER" => R.CURRENT_SERVER[] === nothing,
            "SERVERS" => isempty(R.SERVERS),
            "EXIT_HOOKED" => !R.EXIT_HOOKED[],
            "ROUTING_INSTALLED" => !R.ROUTING_INSTALLED[],
            "REAL_OUT" => R.REAL_OUT[] === devnull,
            "REAL_ERR" => R.REAL_ERR[] === devnull,
            "ACTIVITY_CAPTURE_REQUESTED" => !R.ACTIVITY_CAPTURE_REQUESTED[],
            "ACTIVITY" => isempty(R.ACTIVITY.entries) && R.ACTIVITY.seq == 0 && R.ACTIVITY.open === nothing,
            "RESTARTING" => !R.RESTARTING[],
            "FOOTER" => !R.Footers.FOOTER.started && !R.Footers.FOOTER.enabled && isempty(R.Footers.FOOTER.sections),
            "FOOTER.wake" => !(@atomic R.Footers.FOOTER.wake.set),
            "displays" => !any(d -> d isa R.RouterDisplay, Base.Multimedia.displays),
        ]
        pristine || println(name)
    end
    """
    dirty = readlines(`$(Precompiled.julia_cmd()) -e $script`)
    @test dirty == String[]
end

@testitem "headless_server_and_client_compile_nothing_of_their_own_at_runtime" tags = [:precompile] setup = [Precompiled] begin
    result = Precompiled.runtime_compiles("")
    @test Precompiled.compiling_clients(result) == []
    @test result.server == String[]
end

# An extension's methods invalidate the package code that calls the hooks they
# extend, so each extension's workload compiles that code again into its own image.
@testitem "server_with_repl_extension_compiles_nothing_of_its_own_at_runtime" tags = [:precompile] setup = [Precompiled] begin
    result = Precompiled.runtime_compiles("import REPL;")
    @test Precompiled.compiling_clients(result) == []
    @test result.server == String[]
end

@testitem "server_with_test_extension_compiles_nothing_of_its_own_at_runtime" tags = [:precompile] setup = [Precompiled] begin
    result = Precompiled.runtime_compiles("import Test;")
    @test Precompiled.compiling_clients(result) == []
    # Julia 1.10 keeps REPL in its sysimage, so the REPL extension loads alongside
    # Test. Each extension's image is built without the other, and together they
    # invalidate the eval path both recompiled, so its first eval compiles it again.
    @test result.server == String[] broken = VERSION < v"1.11"
end
