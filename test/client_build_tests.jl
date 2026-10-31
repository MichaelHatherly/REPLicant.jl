@testitem "client_build_loads_only_the_packages_it_uses" tags = [:precompile] setup = [Precompiled] begin
    import REPLicant
    client_mode = joinpath(pkgdir(REPLicant), "bin", "client-mode")
    script = """
    before = Set(keys(Base.loaded_modules))
    push!(LOAD_PATH, $(repr(client_mode)))
    using REPLicant
    REPLicant.CLIENT_ONLY || error("loaded the full build")
    foreach(println, sort([pkg.name for pkg in setdiff(keys(Base.loaded_modules), before)]))
    """
    command = `$(Precompiled.julia_cmd()) -e $script`
    # The first load builds the client image and reports it on stderr.
    run(pipeline(command; stdout = devnull, stderr = devnull))
    err = IOBuffer()
    loaded = readlines(pipeline(command; stderr = err))
    @test "REPLicant" in loaded
    @test filter(!startswith("REPLicant"), loaded) == String[]
    # An extension whose trigger is loaded, such as REPL in Julia 1.10's sysimage,
    # loads with the client build too, and must load cleanly.
    @test String(take!(err)) == ""
end

@testsnippet ClientCompiles begin
    import REPLicant
    # What `call` compiles at runtime in a process running the client build with
    # `flags` and `args`, beyond what loading the build and exiting does.
    function client_compiles(call; flags = ``, args = String[])
        client_mode = joinpath(pkgdir(REPLicant), "bin", "client-mode")
        registry = mktempdir()
        function compiles(code)
            script = "push!(LOAD_PATH, $(repr(client_mode))); using REPLicant; exit($code)"
            trace = tempname()
            command = `$(Precompiled.julia_cmd()) $flags --trace-compile=$trace -e $script $args`
            run(pipeline(addenv(command, "REPLICANT_DIR" => registry); stdout = tempname()))
            return Precompiled.compiles(trace)
        end
        # The first load may build the client image.
        compiles("0")
        return Precompiled.client_held(setdiff(compiles(call), compiles("0")))
    end
end

@testitem "client_build_compiles_nothing_to_find_the_registry" tags = [:precompile] setup = [Precompiled, ClientCompiles] begin
    # Every client call reads the registry, building the default path's name even
    # when `REPLICANT_DIR` overrides it.
    @test client_compiles("(REPLicant._read_entries(); 0)") == String[]
end

@testitem "client_writes_to_forced_color_streams_without_compiling" tags = [:precompile] setup = [Precompiled, ClientCompiles] begin
    # With color forced, as CI and `--color=yes` do, Julia wraps `stdout` in an
    # `IOContext`, so the client writes to a stream type its workload never saw.
    @test client_compiles("REPLicant.cli()"; flags = `--color=yes`, args = ["help"]) == String[]
end
