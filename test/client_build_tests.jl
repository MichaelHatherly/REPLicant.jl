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

@testitem "client_build_compiles_nothing_to_find_the_registry" tags = [:precompile] setup = [Precompiled] begin
    import REPLicant
    client_mode = joinpath(pkgdir(REPLicant), "bin", "client-mode")
    registry = mktempdir()
    # What `call` compiles at runtime in the client build, beyond what loading it does.
    function compiles(call)
        script = "push!(LOAD_PATH, $(repr(client_mode))); using REPLicant; $call"
        trace = tempname()
        command = `$(Precompiled.julia_cmd()) --trace-compile=$trace -e $script`
        run(addenv(command, "REPLICANT_DIR" => registry))
        return isfile(trace) ? readlines(trace) : String[]
    end
    compiles("nothing")
    # Every client call looks up the registry, building the default path's name even
    # when `REPLICANT_DIR` overrides it.
    @test setdiff(compiles("REPLicant._registry_dir()"), compiles("nothing")) == String[]
end
