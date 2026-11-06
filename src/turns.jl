# Turns between the human typing at an interactive REPL and agent evals. Both
# share one process, whose cwd and fds 1/2 an eval changes, so a human command
# waits for agent evals in flight and an agent eval waits for the human's command.
# Agent evals never wait for each other: a test suite runs inside one and queries
# servers it starts in the same process.
mutable struct Turns
    const condition::Threads.Condition
    # Agent evals in flight, across every server in the process.
    agents::Int
    # The id of the human command in flight; 0 when none.
    human::Int
    last_human::Int

    Turns() = new(Threads.Condition(), 0, 0, 0)
end

const TURNS = Turns()

# Run `f` as an agent eval. `own_turn` is the human command that started the
# server, if still running: that command waits on the server's reply, so the
# eval must not wait on it.
function _with_agent_turn(f, turns::Turns, own_turn::Int)
    @lock turns.condition begin
        while turns.human != 0 && turns.human != own_turn
            wait(turns.condition)
        end
        turns.agents += 1
    end
    try
        return f()
    finally
        @lock turns.condition begin
            turns.agents -= 1
            turns.agents == 0 && notify(turns.condition)
        end
    end
end

# The REPL takes the human's turn as the command starts evaluating, on the backend
# task, so Ctrl-C reaches a command waiting for its turn as it would any blocking
# call. It releases the turn once the command has finished and printed, whether it
# returned, threw, or never got its turn.
function _take_human_turn!(turns::Turns = TURNS)
    @lock turns.condition begin
        while turns.human != 0 || turns.agents > 0
            wait(turns.condition)
        end
        turns.last_human += 1
        turns.human = turns.last_human
    end
    return nothing
end

function _release_human_turn!(turns::Turns = TURNS)
    @lock turns.condition begin
        turns.human = 0
        notify(turns.condition)
    end
    return nothing
end

# The REPL extension overrides `__install_turn_gate(::Nothing)` to wrap the prompt
# modes in human turns. Without REPL the `::Any` fallback does nothing.
__install_turn_gate(::Any) = nothing
