@testitem "JET" tags = [:jet] begin
    import JET

    # JET loads only a stub on pre-release Julia and errors when called, so skip
    # the whole analysis there (nightly runs in CI).
    if isempty(VERSION.prerelease)
        # Basic static analysis over REPLicant's own module. A no-method branch
        # or a type-level regression fails here rather than at runtime. Runs on
        # every stable Julia; JET resolves a version-appropriate release per one.
        JET.test_package(REPLicant; target_defined_modules = true, mode = :basic)

        # Sound mode and the optimization analyzer flag more, much of it
        # intentional dynamic dispatch (eval over `Any`, socket IO). Rather than
        # gate at zero, ratchet: cap the count so it can only fall. Lower a limit
        # when the count drops; never raise one without a reason. Counts depend on
        # the Julia and JET versions (JET 0.10 on Julia 1.12), so the ratchet runs
        # only there.
        JET_JULIA = v"1.12"
        # Help mode's `@doc` fallback evaluates and `show`s a docs object of
        # unknown type, so `_help`/`__help`/`_render_md` contribute intentional
        # dynamic-dispatch reports over `Any`; the rest are socket IO and logging.
        # +3 over the prior 308: the output routers (`RouterOut`/`RouterErr`/
        # `RouterDisplay`) write to an abstract `IO` resolved per task, so JET sees
        # intentional dynamic dispatch on `write`/`show`, like the socket IO paths.
        SOUND_LIMIT = 311   # JET.report_package(REPLicant; mode = :sound)
        OPT_LIMIT = 0       # JET.report_opt on _parse_client_args(::Vector{String})

        if (VERSION.major, VERSION.minor) == (JET_JULIA.major, JET_JULIA.minor)
            sound = JET.get_reports(
                JET.report_package(REPLicant; target_defined_modules = true, mode = :sound),
            )
            length(sound) < SOUND_LIMIT &&
                @info "JET sound below limit; lower SOUND_LIMIT to $(length(sound))"
            @test length(sound) <= SOUND_LIMIT

            opt = JET.get_reports(
                JET.report_opt(
                    Tuple{typeof(REPLicant._parse_client_args), Vector{String}};
                    target_modules = (REPLicant,),
                ),
            )
            length(opt) < OPT_LIMIT &&
                @info "JET opt below limit; lower OPT_LIMIT to $(length(opt))"
            @test length(opt) <= OPT_LIMIT
        end
    else
        @test true skip = true
    end
end
