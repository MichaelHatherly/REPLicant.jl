module REPLicantREPLExt

import REPLicant
import REPL
import REPL.LineEdit

# Override the base __help fallback when REPL is available, rendering the full
# help mode: operators, keywords, macros, and apropos `?"text"` search.
function REPLicant.__help(::Nothing, query::AbstractString, mod::Module)
    return try
        io = IOBuffer()
        # helpmode prints a `search: ...` line to `io` and returns a docs object
        # (nothing for apropos `?"text"`, which prints its hits to `io`).
        docs = Core.eval(mod, REPL.helpmode(io, query, mod))
        (; output = String(take!(io)) * REPLicant._render_md(docs, mod), errored = false)
    catch error
        (; output = "ERROR: $(error)", errored = true)
    end
end

#
# Busy indicator: recolor the `julia>` prompt and set the terminal title while a
# remote evaluation is in flight.
#

const BUSY_COLOR = Base.text_colors[:yellow]
const INSTALL_LOCK = ReentrantLock()
const INSTALLED = Ref(false)
const TERMINAL = Ref{Any}(nothing)

# The interactive `julia>` prompt among the REPL's modes, found by its rendered
# text rather than position to avoid coupling to mode ordering.
function _julia_prompt(repl)
    for mode in repl.interface.modes
        mode isa LineEdit.Prompt || continue
        endswith(LineEdit.prompt_string(mode.prompt), "julia> ") && return mode
    end
    return nothing
end

# Install the busy hooks once. The server starts from startup.jl before the
# interactive REPL exists, so resolve `active_repl` lazily on first signal.
function _install!()
    INSTALLED[] && return true
    return lock(INSTALL_LOCK) do
        INSTALLED[] && return true
        (isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL) || return false
        repl = Base.active_repl
        prompt = _julia_prompt(repl)
        prompt === nothing && return false
        # The prefix carries no display width, so recoloring never disturbs the
        # cursor math; idle restores the REPL's configured color.
        original_prefix = prompt.prompt_prefix
        prompt.prompt_prefix =
            () -> REPLicant._is_busy() ? BUSY_COLOR : LineEdit.prompt_string(original_prefix)
        TERMINAL[] = repl.t
        INSTALLED[] = true
        return true
    end
end

function REPLicant.__notify_busy(::Nothing)
    _install!() || return nothing
    busy = REPLicant._is_busy()

    # OSC 2 sets the terminal title on the captured real terminal, bypassing the
    # stdout redirection that eval installs.
    terminal = TERMINAL[]
    if terminal !== nothing
        title = busy ? "● julia — remote eval" : "julia"
        print(terminal, "\e]2;", title, "\a")
    end

    # Repaint the prompt so the recolor shows while the user sits idle. Uses the
    # same async channel the REPL uses for the Pkg-mode switch; absent on Julia
    # 1.10, where the recolor lands on the next natural render.
    repl = Base.active_repl
    if isdefined(repl, :mistate) && repl.mistate !== nothing && hasproperty(repl.mistate, :async_channel)
        try
            put!(
                repl.mistate.async_channel, function (s)
                    LineEdit.refresh_line(s)
                    return :ok
                end
            )
        catch  # dendro-ignore: empty_catch -- async channel closed during REPL shutdown
        end
    end

    return nothing
end

end
