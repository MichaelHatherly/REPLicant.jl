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
# Busy indicator: animate the `julia>` prompt and set the terminal title while a
# remote evaluation is in flight.
#

const INSTALL_LOCK = ReentrantLock()
const INSTALLED = Ref(false)
const TERMINAL = Ref{Any}(nothing)

# Animation state. `FRAME` advances one step per timer tick; `ANIM` holds the
# running timer so a second busy signal does not start a second one. Frame cadence
# in seconds.
const FRAME = Ref(0)
const ANIM = Ref{Union{Timer, Nothing}}(nothing)
const FRAME_SECONDS = 0.12

# Wrap one prompt mode's text with the busy animation. The closure captures this
# mode's own original prompt, so idle restores exactly what was there, in its
# default color. The animated frame keeps the prompt's display width, so swapping
# it in never shifts typed input.
function _animate!(prompt)
    original_prompt = prompt.prompt
    prompt.prompt =
        () -> REPLicant._is_busy() ?
        REPLicant._busy_frame(LineEdit.prompt_string(original_prompt), FRAME[]) :
        LineEdit.prompt_string(original_prompt)
    return nothing
end

# Install the busy hooks once, across every prompt mode (julia, pkg, help, shell).
# The server starts from startup.jl before the interactive REPL exists, so resolve
# `active_repl` lazily on first signal.
function _install!()
    INSTALLED[] && return true
    return lock(INSTALL_LOCK) do
        INSTALLED[] && return true
        (isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL) || return false
        repl = Base.active_repl
        for mode in repl.interface.modes
            mode isa LineEdit.Prompt && _animate!(mode)
        end
        TERMINAL[] = repl.t
        INSTALLED[] = true
        return true
    end
end

# Repaint the prompt from the REPL render thread. Uses the same async channel the
# REPL uses for the Pkg-mode switch; absent on Julia 1.10, where the change lands
# on the next natural render.
function _request_refresh()
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

    # Drive the animation: start a repeating timer on the first busy signal, stop
    # it when work clears and repaint once to restore the idle prompt.
    if busy
        if ANIM[] === nothing
            ANIM[] = Timer(FRAME_SECONDS; interval = FRAME_SECONDS) do _
                FRAME[] += 1
                _request_refresh()
            end
        end
    elseif ANIM[] !== nothing
        close(ANIM[])
        ANIM[] = nothing
        FRAME[] = 0
        _request_refresh()
    end

    return nothing
end

end
