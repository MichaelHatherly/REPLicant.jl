@testmodule TurnHarness begin
    import REPLicant

    # Hold the human's turn in a task until `release` is notified, as a command
    # typed at the REPL does while it runs.
    function hold_human_turn(turns, release)
        task = @async begin
            REPLicant._take_human_turn!(turns)
            try
                wait(release)
            finally
                REPLicant._release_human_turn!(turns)
            end
        end
        timedwait(() -> turns.human != 0, 5) === :ok || error("human turn not taken")
        return task
    end
end

@testitem "agent_eval_waits_for_human_turn" tags = [:repl_turn] setup = [Utilities, TurnHarness] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        turns = server.turns = REPLicant.Turns()
        release = Base.Event()
        human = TurnHarness.hold_human_turn(turns, release)

        agent = @async Utilities.request(port, "1 + 1")
        @test timedwait(() -> istaskdone(agent), 0.5) === :timed_out

        notify(release)
        wait(human)
        @test fetch(agent) == "2"
        @test turns.agents == 0
    end
end

@testitem "human_turn_waits_for_agent_turn" tags = [:repl_turn] begin
    import REPLicant

    turns = REPLicant.Turns()
    release = Base.Event()
    agent = @async REPLicant._with_agent_turn(() -> wait(release), turns, 0)
    @test timedwait(() -> turns.agents == 1, 5) === :ok

    human = @async REPLicant._take_human_turn!(turns)
    @test timedwait(() -> istaskdone(human), 0.5) === :timed_out

    notify(release)
    wait(human)
    @test turns.human != 0 && turns.agents == 0
    REPLicant._release_human_turn!(turns)
    @test turns.human == 0
end

@testitem "agent_turns_do_not_exclude_each_other" tags = [:repl_turn] begin
    import REPLicant

    turns = REPLicant.Turns()
    nested = REPLicant._with_agent_turn(turns, 0) do
        REPLicant._with_agent_turn(() -> turns.agents, turns, 0)
    end
    @test nested == 2
    @test turns.agents == 0
end

@testitem "server_started_in_human_turn_skips_its_wait" tags = [:repl_turn] setup = [Utilities, TurnHarness] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        # A human command that starts a server and then queries it, as running the
        # test suite at the prompt does, must not wait on its own turn.
        turns = REPLicant.Turns()
        release = Base.Event()
        human = TurnHarness.hold_human_turn(turns, release)
        REPLicant._claim_turns!(server, turns)
        @test Utilities.request(port, "1 + 1") == "2"
        notify(release)
        wait(human)

        # Once that command ends, the server's evals wait for later ones.
        release = Base.Event()
        human = TurnHarness.hold_human_turn(turns, release)
        agent = @async Utilities.request(port, "2 + 2")
        @test timedwait(() -> istaskdone(agent), 0.5) === :timed_out
        notify(release)
        wait(human)
        @test fetch(agent) == "4"
    end
end

@testitem "interrupt_frees_eval_waiting_for_turn" tags = [:repl_turn, :interrupt] setup = [Utilities, TurnHarness] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        turns = server.turns = REPLicant.Turns()
        release = Base.Event()
        human = TurnHarness.hold_human_turn(turns, release)

        waiting = @async Utilities.request(port, "1 + 1")
        @test timedwait(() -> !isnothing(server.busy_since), 5) === :ok
        frame = Utilities.requestframe(port, REPLicant.REQUEST_INTERRUPT, "")
        @test frame.body == "interrupted"
        @test occursin("Interrupt", fetch(waiting))
        @test turns.agents == 0

        notify(release)
        wait(human)
        @test Utilities.request(port, "3 + 3") == "6"
    end
end

@testitem "turn_gate_takes_turn_in_command_and_releases_after" tags = [:repl_turn] begin
    import REPLicant
    import REPL

    ext = Base.get_extension(REPLicant, :REPLicantREPLExt)
    turns = REPLicant.Turns()
    transforms = Any[REPL.softscope]
    ext._gate_backend!(transforms, turns)
    ext._gate_backend!(transforms, turns)
    @test count(xf -> xf isa ext.TakeTurn, transforms) == 1

    # The backend runs the transformed command, which holds the turn while it runs.
    mod = Module()
    ast = foldl((ast, xf) -> xf(ast), transforms; init = :(seen = $turns.human))
    Core.eval(mod, ast)
    @test mod.seen > 0

    # The frontend's `on_done` returns once the command has printed, or thrown.
    prompt = REPL.LineEdit.Prompt("t> "; on_done = (s, buf, ok) -> error("display failed"))
    ext._gate_prompt!(prompt, turns)
    ext._gate_prompt!(prompt, turns)
    @test !(prompt.on_done.on_done isa ext.ReleaseTurn)
    @test_throws ErrorException prompt.on_done(nothing, IOBuffer(), true)
    @test turns.human == 0
end
