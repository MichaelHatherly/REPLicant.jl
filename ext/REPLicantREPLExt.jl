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
# Busy indicator: set the terminal title while a remote evaluation is in flight.
#

const TERMINAL = Ref{Any}(nothing)

# The server starts from startup.jl before the interactive REPL exists, so resolve
# the terminal lazily on first signal.
function _terminal()
    TERMINAL[] === nothing || return TERMINAL[]
    (isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL) || return nothing
    return TERMINAL[] = Base.active_repl.t
end

function REPLicant.__notify_busy(::Nothing)
    terminal = _terminal()
    terminal === nothing && return nothing
    # OSC 2 sets the title on the real terminal, bypassing the stdout redirection
    # that eval installs.
    title = REPLicant._is_busy() ? "● julia — remote eval" : "julia"
    print(terminal, "\e]2;", title, "\a")
    return nothing
end

#
# Footer: rebind Ctrl-L, which would otherwise wipe the reserved rows.
#
# The REPL binds it to erasing the whole screen, and erase-in-display ignores the
# scrolling region, so the footer goes with it and a footer nothing is currently
# updating never comes back. What Ctrl-L is for is clearing the scrollback out of
# the way, so the replacement clears the scrolling region and leaves the reserved
# rows alone. Nothing is erased, so there is no flash to repair. With the footer
# disabled it reserves nothing and clears the whole screen, as the original did.
#

const FOOTER_KEYS_INSTALLED = Ref(false)

function _clear_scrolling_region(state, rest...)
    terminal = LineEdit.terminal(state)
    try
        write(terminal, REPLicant.Footers.clear_screen_sequence())
    catch error
        @debug "Footer clear failed" exception = (error, catch_backtrace())
        REPL.Terminals.clear(terminal)
    end
    LineEdit.refresh_line(state)
    return nothing
end

# Called from the footer's upkeep until it takes: the footer can be enabled from
# `startup.jl`, before the REPL has built the keymaps this patches.
function REPLicant.Footers.__install_keys(::Nothing)
    FOOTER_KEYS_INSTALLED[] && return true
    (isdefined(Base, :active_repl) && Base.active_repl isa REPL.LineEditREPL) || return false
    repl = Base.active_repl
    isdefined(repl, :interface) || return false
    for mode in repl.interface.modes
        if hasproperty(mode, :keymap_dict) && mode.keymap_dict isa Dict{Char, Any}
            LineEdit.add_nested_key!(
                mode.keymap_dict, '\x0c', _clear_scrolling_region; override = true
            )
        end
    end
    FOOTER_KEYS_INSTALLED[] = true
    return true
end

#
# Activity log: capture human-typed input into the log, so an agent sharing the
# session sees what was run at the prompt.
#

const REPL_TRANSFORM_INSTALLED = Ref(false)

# Reproduce the human's typed code from the parsed expression. `ast_transforms` never
# sees the raw source, so deparse: strip line-number nodes and print. Normalized
# (comments and exact spacing are lost), faithful to what ran. Deep-copy before
# stripping so the expression the REPL is about to evaluate is left untouched.
function _deparse(@nospecialize ast)
    ast isa Expr || return string(ast)
    stripped = Base.remove_linenums!(deepcopy(ast))
    # `remove_linenums!` clears line nodes inside blocks but leaves those sitting
    # directly in a `:toplevel` (multi-statement input), so drop them here.
    stripped.head === :toplevel && return join(
        (string(arg) for arg in stripped.args if !(arg isa LineNumberNode)), '\n',
    )
    return string(stripped)
end

# An identity AST transform: it records the typed line into the activity log, then
# returns its input unchanged so evaluation is unaffected. It never throws into the
# REPL. Runs on the REPL backend task, before the line evaluates.
function _repl_input_transform(@nospecialize ast)
    try
        REPLicant._record_repl_input(_deparse(ast))
    catch  # dendro-ignore: empty_catch -- a logging failure must never disturb the human's REPL
    end
    return ast
end

# Push the transform once. Onto the live backend when it exists, else onto the
# template `REPLBackend` copies at startup, covering both boot orders (server from
# startup.jl before the backend, or loaded into a running REPL). `pushfirst!` so it
# observes the raw parsed expression before `softscope` wraps it.
function _push_repl_transform()
    REPL_TRANSFORM_INSTALLED[] && return nothing
    if isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing
        pushfirst!(Base.active_repl_backend.ast_transforms, _repl_input_transform)
    else
        pushfirst!(REPL.repl_ast_transforms, _repl_input_transform)
    end
    REPL_TRANSFORM_INSTALLED[] = true
    return nothing
end

function REPLicant.__install_activity_capture(::Nothing)
    # atreplinit runs before `REPLBackend()` copies the transform template, so a
    # transform pushed there is inherited by the backend. The direct push covers the
    # case where the backend already exists.
    atreplinit(_ -> _push_repl_transform())
    _push_repl_transform()
    return nothing
end

end
