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
