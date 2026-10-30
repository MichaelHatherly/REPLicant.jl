@testitem "JET" tags = [:jet] begin
    import JET

    # JET loads only a stub on pre-release Julia and errors when called, so skip
    # the whole analysis there (nightly runs in CI).
    if isempty(VERSION.prerelease)
        # Basic static analysis over REPLicant's own module. A no-method branch
        # or a type-level regression fails here rather than at runtime. Runs on
        # every stable Julia; JET resolves a version-appropriate release per one.
        JET.test_package(REPLicant; target_modules = (REPLicant,), mode = :basic)

        # Sound mode and the optimization analyzer flag more, much of it
        # intentional dynamic dispatch (eval over `Any`, socket IO). Rather than
        # gate at zero, ratchet: cap the count so it can only fall. Lower a limit
        # when the count drops; never raise one without a reason. Counts depend on
        # the Julia and JET versions (JET 0.13 on Julia 1.13), so the ratchet runs
        # only there.
        JET_JULIA = v"1.13"
        # The count is intentional dynamic dispatch: eval over `Any`, sound-mode
        # `getfield`/`setfield` on the `cli`/parser NamedTuples and the server's
        # `busy_since`/`interrupt_signal`, and abstract-IO `write`/`show` across the
        # socket paths, the per-task output `Router`, the `ls` status table, and
        # `_capture`'s pipe reader. Help mode's `@doc` fallback `show`s a docs object
        # of unknown type. The `kill`, `--timeout`, and `interrupt` paths add
        # socket-IO and `println`-over-`IO` reports in the same category; running
        # each eval in its own `@async` task, with a watcher that schedules the
        # interrupt, adds a few more. The eval frame's `cwd`/module fields, named
        # sessions (`Core.eval` building a module under the session lock), and the
        # `reset` and `start` subcommands (subprocess `run`/`Cmd`, the `--channel`
        # launcher, and more keyword-NamedTuple `getfield` over `out`/`err`) account
        # for the rest. The `help` usage text, the `interrupt` idle-confirmation
        # poll (`_ping_status` over the socket), and the reserved-session check add
        # the last few in the same IO/dispatch category. The `start` version guard's
        # injectable `manifest_version_of`/`channel_version_of` resolvers (a test
        # seam so the version-comparison logic doesn't need a second Julia channel
        # installed) add a few more `Function`-typed-callable and keyword-NamedTuple
        # dispatches in the same category. The callable default eval target
        # (`_default_target(::Base.Callable)` resolved per request) adds
        # `Function`-typed-callable dispatches likewise. The activity log adds one
        # more cohort in the same category: the `log` subcommand's socket IO and
        # keyword-NamedTuple `getfield` over `out`/`err`, the render's `println`/`show`
        # over the entries, `_parse_log_spec`'s NamedTuple `getfield`, the `Router`'s
        # tee of unbound output, and `RouterDisplay`'s `show` of the REPL's displayed
        # result values (over `Any`) into the log. Threading stays inferrable: opt is 0.
        # Client-side output eliding (`--head-lines`/`--tail-lines`) adds the last
        # cohort in the same category: `_parse_number`'s predicate-callable dispatch,
        # the `head_lines`/`tail_lines` keyword-NamedTuple dispatch through `_send`,
        # and `_elide`'s `split`/`join` over the abstract-IO response body. Logging a
        # foreign peer at debug adds the log macro's `shouldlog` pair, and the
        # `UnknownProtocol` constructor its field `convert`. The footer is the largest
        # single cohort, all of it the same two kinds: a section holds its content as
        # `Any` and renders it through `invokelatest`, and every row of drawing is
        # `write`/`string` over abstract IO. The status row's reads of the server
        # handle's `Union`-typed runtime details add the `getfield` remainder. The
        # request token adds a keyword to the registry writers and an `Unauthorized`
        # branch to `_reply_error`'s test of an `Any`-typed error. The shared registry
        # scan adds the prune and label scans' `==` of an entry's `project` field
        # against an `AbstractString` argument. Revising inside `_handle_eval` adds
        # the result's typeassert after the `__revise` extension point. The footer's
        # upkeep reaches the REPL extension's key binding through `invokelatest`,
        # which may throw. `kill` reporting a surviving process adds an `err`
        # keyword's `getfield`. Rejecting a request for its content adds the
        # `RequestError` constructor's field `convert` and its `@debug` log's
        # `shouldlog` pair. Refusing an unknown session adds a `string` over the
        # `AbstractString` name. Handing a spawned child the router's stream adds a
        # `setup_stdio` call over the abstract real stream and its uncovered match.
        # `restart` adds its subcommand's keyword-NamedTuple `getfield` over
        # `out`/`err`, and the re-exec's `flush` of the global `stdout`/`stderr` and
        # its failure `@error`. Reading a request in three steps (header, token, body)
        # adds keyword `getfield`s to `_read_header`, `_read_body`, and the chunked
        # `_discard_body`, plus `TruncatedFrame`'s field `convert`s. The rest are in
        # the same categories: `CaptureSink`'s outer field, the single exit hook over
        # `SERVERS`, the footer's `visible`/`max_rows`/`prompt_evaluating` over
        # `Any` widths and the REPL backend, and keyword `getfield`s on `_cap`,
        # `_kill_target`, and `repaint!`. Holding the activity log in `ActivityLog` and
        # the footer's live predicate and disturbed flag in `Footer` adds their
        # constructors' field `convert`s.
        SOUND_LIMIT = 752   # JET.report_package(REPLicant; mode = :sound)
        OPT_LIMIT = 0       # JET.report_opt on _parse_args(::Vector{String})

        if (VERSION.major, VERSION.minor) == (JET_JULIA.major, JET_JULIA.minor)
            sound = JET.get_reports(
                JET.report_package(REPLicant; target_modules = (REPLicant,), mode = :sound),
            )
            length(sound) < SOUND_LIMIT &&
                @info "JET sound below limit; lower SOUND_LIMIT to $(length(sound))"
            @test length(sound) <= SOUND_LIMIT

            opt = JET.get_reports(
                JET.report_opt(
                    Tuple{typeof(REPLicant._parse_args), Vector{String}};
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
