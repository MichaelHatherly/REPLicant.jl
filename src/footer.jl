#
# Pinned terminal footer.
#
# The last `n` rows of the terminal are removed from the scrolling region, so the
# footer can be repainted while the REPL keeps scrolling underneath it and the
# human keeps typing at the prompt. It does what a status display needs: no
# scrolling, no keyboard control, no logger.
#
# Nothing here reaches into the line editor. A repaint only touches rows outside
# the scrolling region and brackets itself in a cursor save and restore, so the
# prompt is never moved or redrawn. Both sides emit a redraw as a single `write`,
# which is what stops them tearing each other's escape sequences: one write to a
# terminal cannot land inside another.
#
# A submodule, because the vocabulary of drawing (`paint`, `fit`, `render`,
# `window`) is generic enough to collide with REPLicant's own if it were flat. The
# dependency runs one way: this module knows nothing about servers or activity
# logs, and `status.jl` hands it the content to draw.

module Footers

# Terminal control
#
# `paint` is pure: it takes the number of rows the footer occupied on the previous
# repaint and returns the byte string that moves it to its new size and contents.
# Keeping it pure is what makes the row arithmetic testable, and the whole sequence
# is written in one `write` call so the update is as close to atomic as the
# terminal allows.

"""
    escape_end(line, i)

The index just past the ANSI escape sequence starting at `i`.

One definition of where a sequence ends, for everything here that has to step
over them without counting them as text.
"""
function escape_end(line::AbstractString, i::Integer)
    stop = lastindex(line)
    j = nextind(line, i)
    if j <= stop && line[j] == '['
        j = nextind(line, j)
        while j <= stop && !('\u40' <= line[j] <= '\u7e')
            j = nextind(line, j)
        end
    end
    return j <= stop ? nextind(line, j) : j
end

"""
    display_width(line)

The columns `line` occupies, ignoring ANSI escape sequences.
"""
function display_width(line::AbstractString)
    width = 0
    stop = lastindex(line)
    i = firstindex(line)
    while i <= stop
        c = line[i]
        if c == '\e'
            i = escape_end(line, i)
        else
            width += textwidth(c)
            i = nextind(line, i)
        end
    end
    return width
end

"""
    fit(line, width)

Truncate `line` to `width` display columns, passing ANSI escape sequences
through without counting them.
"""
function fit(line::AbstractString, width::Integer)
    width <= 0 && return ""
    io = IOBuffer()
    used = 0
    stop = lastindex(line)
    i = firstindex(line)
    while i <= stop
        c = line[i]
        if c == '\e'
            j = escape_end(line, i)
            write(io, SubString(line, i, prevind(line, j)))
            i = j
        else
            w = textwidth(c)
            used + w > width && break
            write(io, c)
            used += w
            i = nextind(line, i)
        end
    end
    return String(take!(io))
end

# Section content
#
# A section holds a value, not a rendering. Rendering happens at paint time against
# the terminal size the footer has right then, so width-sensitive content stays
# correct across a resize instead of being frozen at whatever the width was when
# `set!` was called. It is also what lets a section read live state: a closure over
# the server handle is re-consulted on every repaint.
#
# Strings are taken as written. A function is called with the width. Anything
# else is asked to show itself through `show(::IO, ::MIME"text/plain", x)` with
# the size in the `IOContext`, which is the protocol Julia already uses for
# rendering a value into a given amount of space.

"""
    Section(value, rows)

Footer content and an optional cap on the rows it may occupy.
"""
struct Section
    value::Any
    rows::Union{Nothing, Int}
end

# Content the caller wrote out line by line is as long as they made it. Content
# a value produced for itself is open ended, so it gets a default worth seeing
# without losing the prompt.
const DEFAULT_SHOW_ROWS = 8

default_rows(::Union{AbstractString, Function}, height::Integer) = max(height - 1, 0)
default_rows(::Any, height::Integer) = min(DEFAULT_SHOW_ROWS, max(height - 1, 0))

"""
    render(value, rows, width)

The lines `value` occupies when given `rows` by `width` to render into.

Sections hold whatever the caller passed, which routinely means a closure typed at
the prompt or a type defined after the painting task was spawned. Calling either
from that task is a world age error, so both go through `invokelatest`.
"""
render(text::AbstractString, ::Integer, ::Integer) =
    isempty(text) ? String[] : collect(String, split(chomp(text), '\n'))
render(f::Function, rows::Integer, width::Integer) =
    render(Base.invokelatest(f, width), rows, width)
function render(value, rows::Integer, width::Integer)
    buf = IOBuffer()
    io = IOContext(
        buf,
        :displaysize => (max(rows, 1), max(width, 1)),
        :limit => true,
        :color => something(Base.have_color, false),
    )
    Base.invokelatest(show, io, MIME"text/plain"(), value)
    return render(String(take!(buf)), rows, width)
end

"""
    window(lines, budget)

The last `budget` rows of `lines`.

Content that outgrows its rows is shown from the bottom, because the reason to
watch a footer is what just happened rather than what happened first.
"""
function window(lines::AbstractVector{<:AbstractString}, budget::Integer)
    budget <= 0 && return String[]
    length(lines) <= budget && return collect(lines)
    return collect(lines[(end - budget + 1):end])
end

function section_lines(section::Section, height::Integer, width::Integer)
    budget = section.rows === nothing ? default_rows(section.value, height) : section.rows
    budget <= 0 && return String[]
    return window(render(section.value, budget, width), budget)
end

"""
    footer_lines(sections, height, width)

The screen rows `label => section` pairs occupy.
"""
function footer_lines(sections, height::Integer, width::Integer)
    lines = String[]
    for (label, section) in sections
        # A section renders caller-supplied code. One that throws loses its own
        # rows, not the whole footer and not the task doing the painting.
        try
            append!(lines, section_lines(section, height, width))
        catch err
            push!(lines, "\e[31m$label: $(sprint(showerror, err))\e[0m")
        end
    end
    return lines
end

"""
    paint(prev, lines, height, width; force_region = false, clear_rows = 1:0)

Byte string that redraws a footer of `lines` over one that occupied `prev` rows.
Pass `force_region` when the terminal's scrolling region can no longer be
trusted, so that it is set even if the footer has not changed size, and
`clear_rows` for rows holding footer text the footer no longer owns.
"""
function paint(
        prev::Integer,
        lines::AbstractVector{<:AbstractString},
        height::Integer,
        width::Integer;
        force_region::Bool = false,
        clear_rows = 1:0,
    )
    # The footer never claims the row the prompt sits on.
    n = min(length(lines), max(height - 1, 0))
    n == 0 && prev == 0 && !force_region && isempty(clear_rows) && return ""

    io = IOBuffer()
    write(io, "\e7")
    if n > prev
        # Growing the footer shrinks the scrolling region from the bottom, which
        # would overwrite whatever sits in the rows being claimed. Scroll the old
        # region up first so the prompt moves clear of them.
        write(io, "\e[$(n - prev)S")
    end
    if n != prev || force_region
        # DECSTBM homes the cursor, which the restore at the end undoes.
        write(io, "\e[1;$(height - n)r")
    end
    # Cleared before the footer is drawn, so an overlapping row keeps its text.
    for row in clear_rows
        write(io, "\e[$row;1H\e[K")
    end
    for i in 1:n
        write(io, "\e[$(height - n + i);1H", fit(lines[i], width), "\e[0m\e[K")
    end
    # Rows handed back to the scrolling region still hold old footer text.
    for row in (height - prev + 1):(height - n)
        write(io, "\e[$row;1H\e[K")
    end
    write(io, "\e8")
    if n > prev
        # The restored cursor is in the row the prompt used to occupy, and the
        # scroll above moved the prompt out of it.
        write(io, "\e[$(n - prev)A")
    end
    return String(take!(io))
end

"""
    clear_region_sequence(height, reserved)

Byte string that blanks the scrolling region and homes the cursor, leaving the
`reserved` rows at the bottom as they are.
"""
function clear_region_sequence(height::Integer, reserved::Integer)
    io = IOBuffer()
    for row in 1:(height - reserved)
        write(io, "\e[$row;1H\e[K")
    end
    write(io, "\e[1;1H")
    return String(take!(io))
end

"""
    vacated_rows(rows, was_height, height)

Rows still holding footer text that the footer will not paint over, for a footer
of `rows` drawn into a terminal `was_height` tall and now being drawn into one
`height` tall.

Terminals anchor the screen differently depending on which way it resized.
Losing height keeps the bottom fixed, so the old footer stays in the rows the
new one claims and gets overwritten. Gaining height keeps the top fixed, so the
old footer keeps its row numbers while the new one moves down to the new bottom,
leaving the old text stranded.
"""
function vacated_rows(rows::Integer, was_height::Integer, height::Integer)
    rows == 0 && return 1:0
    height > was_height || return 1:0
    return max(was_height - rows + 1, 1):min(was_height, height)
end

"""
    reflowed_rows(widths, width)

How many screen rows lines of these widths occupy once the terminal is `width`
columns wide.

Narrowing the terminal makes it rewrap what is already on screen, and the
footer's own rows are no exception: a row wider than the new width comes back as
two, in the scrolling region, above the freshly painted footer. Knowing what was
painted is what makes those removable without guessing at rows that hold real
output.
"""
reflowed_rows(widths, width::Integer) =
    width <= 0 ? 0 : sum(w -> max(cld(w, width), 1), widths; init = 0)

"""
    Painted(rows, height, width, widths)

What the footer last put on screen: how many rows, the terminal it was drawn
into, and the columns each row took.

The next repaint reasons entirely from this. The screen cannot be read back, so
the only account of it is the one kept here.
"""
struct Painted
    rows::Int
    height::Int
    width::Int
    widths::Vector{Int}
end

Painted() = Painted(0, 0, 0, Int[])

"""
    abandoned_rows(painted, n, height, width)

Rows holding footer text that the footer is about to stop owning, given that it
is being repainted as `n` rows on a `height` by `width` terminal.

Losing height strands the old footer at its old row numbers. Losing width leaves
the terminal's rewrap of it just above the new one. Both leave text behind that
nothing else will clear.
"""
function abandoned_rows(painted::Painted, n::Integer, height::Integer, width::Integer)
    rows = collect(vacated_rows(painted.rows, painted.height, height))
    if width < painted.width
        # Only a rewrap needing more rows than it had moves anything: the old
        # footer is pushed clear of the band and every one of its rows left
        # behind. Rows that still fit stay where they were and are painted over,
        # so clearing there would take real output with them.
        spread = reflowed_rows(painted.widths, width)
        spread > painted.rows &&
            append!(rows, max(height - n - spread + 1, 1):(height - n))
    end
    return rows
end

# Live footer

mutable struct Footer
    io::IO
    sections::Vector{Pair{Any, Section}}
    painted::Painted
    stale::Bool
    enabled::Bool
    started::Bool
    wake::Base.Event
    lock::ReentrantLock
end

Footer(io::IO) = Footer(
    io,
    Pair{Any, Section}[],
    Painted(),
    false,
    false,
    false,
    Base.Event(true),
    ReentrantLock(),
)

const FOOTER = Footer(stdout)

# Content that changes on its own clock, rather than only when something calls
# `set!`: an elapsed time counting up, a progress figure read from elsewhere. The
# predicate is consulted on every upkeep tick and a repaint follows while it holds,
# which is how a section can tick without this module knowing what it is showing.
const LIVE = Ref{Union{Nothing, Base.Callable}}(nothing)

"""
    live!(predicate)

Repaint on every upkeep tick for as long as `predicate` returns true. Pass
`nothing` to stop.
"""
function live!(predicate::Union{Nothing, Base.Callable})
    LIVE[] = predicate
    return nothing
end

"""
    set!(label, value; rows = nothing)

Show `value` in the footer under `label`, replacing anything already there.
Sections display in insertion order, and are drawn once [`enable!`](@ref) has
reserved the rows to draw them in.

A string is shown as written, with embedded newlines becoming extra rows. A
function is called with the current width, for content that has to be redrawn
when the terminal changes size or that reads state that moves under it. Anything
else is asked to show itself at the size the footer has.

`rows` caps how many rows the section may take, and is the height a value is told
it has. It is a ceiling rather than a target: `show` methods commonly hold rows
back for a prompt, so a value may come out shorter than its cap. Left unset, a
string or a function is as long as it makes itself, and anything else gets
$DEFAULT_SHOW_ROWS rows so that one careless value cannot take the screen.

Rendering happens on every repaint, so it wants to be cheap.
"""
function set!(
        label,
        value,
        footer::Footer = FOOTER;
        rows::Union{Nothing, Integer} = nothing,
    )
    section = Pair{Any, Section}(label, Section(value, rows === nothing ? nothing : Int(rows)))
    Base.@lock footer.lock begin
        i = findfirst(p -> isequal(first(p), label), footer.sections)
        if i === nothing
            push!(footer.sections, section)
        else
            footer.sections[i] = section
        end
    end
    return update!(footer)
end

"""
    clear!([label])

Remove one labelled section, or every section, from the footer.
"""
function clear!(label, footer::Footer = FOOTER)
    Base.@lock footer.lock filter!(p -> !isequal(first(p), label), footer.sections)
    return update!(footer)
end

function clear!(footer::Footer = FOOTER)
    Base.@lock footer.lock empty!(footer.sections)
    return update!(footer)
end

"""
    update!()

Repaint at the next opportunity, for a section whose content has changed under
the footer. Cheaper than [`refresh!`](@ref), which also forces the scrolling
region back.
"""
function update!(footer::Footer = FOOTER)
    notify(footer.wake)
    return nothing
end

"""
    refresh!()

Repaint the footer, forcing the scrolling region back. Needed after something
else has disturbed it.
"""
function refresh!(footer::Footer = FOOTER)
    Base.@lock footer.lock footer.stale = true
    return update!(footer)
end

# Write the footer update as a single `write`, so it cannot land inside one of
# the line editor's redraws.
function repaint!(footer::Footer)
    sections = Base.@lock footer.lock begin
        # A disabled footer owns no rows. `disable!` hands them back itself.
        footer.enabled || return nothing
        copy(footer.sections)
    end
    height, width = displaysize(footer.io)
    # Sections render caller-supplied code, so it runs without the lock held. A slow
    # one holds up the next repaint, which is unavoidable, but it must not also
    # block `set!` and every other caller behind it.
    lines = footer_lines(sections, height, width)

    bytes = Base.@lock footer.lock begin
        footer.enabled || return nothing
        n = min(length(lines), max(height - 1, 0))
        # A resize resets DECSTBM, so the region has to be claimed again.
        resized = (height, width) != (footer.painted.height, footer.painted.width)
        painted = paint(
            footer.painted.rows,
            lines,
            height,
            width;
            force_region = resized || footer.stale,
            clear_rows = abandoned_rows(footer.painted, n, height, width),
        )
        footer.painted = Painted(n, height, width, [min(display_width(line), width) for line in lines[1:n]])
        footer.stale = false
        painted
    end
    isempty(bytes) || write(footer.io, bytes)
    return nothing
end

# One task owns every write to the reserved rows, so repaints cannot interleave
# with each other however many tasks are calling `set!`. Waking on an event
# rather than repainting inside `set!` also coalesces a burst of updates into a
# single redraw, and keeps callers off the terminal entirely.
function dispatch(footer::Footer)
    while true
        wait(footer.wake)
        footer.enabled || continue
        try
            repaint!(footer)
        catch err
            @debug "Footer repaint failed" exception = (err, catch_backtrace())
        end
    end
    return nothing
end

# Resize notification
#
# Terminals reset the scrolling region on resize and the row arithmetic is stale
# afterwards, so the footer has to hear about it. Julia exposes nothing for this,
# but the libuv it already links does, and SIGWINCH is what the terminal sends.
# The C callback runs on the libuv thread, so it does the least it can and wakes
# a Julia task through an async condition.

const SIGWINCH = Cint(28)
# Built when the signal is armed, since a libuv handle cannot be baked into a
# precompiled image.
const RESIZED = Ref{Base.AsyncCondition}()
const RESIZE_ARMED = Ref(false)

# Deliberately the C allocator rather than a Julia array. libuv frees whatever
# handles are left in its loop when the process winds down, and handing it
# memory the C allocator does not own aborts on the way out. Not freed here
# either, for the same reason: the loop owns it from `uv_signal_init` onwards.
# Every uv handle is far smaller than this, so the exact struct size does not
# matter.
const RESIZE_HANDLE = Ref{Ptr{Cvoid}}(C_NULL)
const HANDLE_BYTES = 4096

function on_sigwinch(::Ptr{Cvoid}, ::Cint)
    ccall(:uv_async_send, Cint, (Ptr{Cvoid},), RESIZED[].handle)
    return nothing
end

# Arming twice would re-initialise a handle libuv is already holding.
function arm_resize_signal()
    RESIZE_ARMED[] && return true
    isassigned(RESIZED) || (RESIZED[] = Base.AsyncCondition())
    if RESIZE_HANDLE[] == C_NULL
        RESIZE_HANDLE[] = Libc.malloc(HANDLE_BYTES)
        RESIZE_HANDLE[] == C_NULL && return false
        ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), RESIZE_HANDLE[], 0, HANDLE_BYTES)
    end
    handle = RESIZE_HANDLE[]
    started = ccall(
        :uv_signal_init,
        Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}),
        Base.eventloop(),
        handle,
    ) == 0 && ccall(
        :uv_signal_start,
        Cint,
        (Ptr{Cvoid}, Ptr{Cvoid}, Cint),
        handle,
        @cfunction(on_sigwinch, Cvoid, (Ptr{Cvoid}, Cint)),
        SIGWINCH,
    ) == 0
    RESIZE_ARMED[] = started
    return started
end

function watch_signal(footer::Footer)
    while true
        wait(RESIZED[])
        footer.enabled && notify(footer.wake)
    end
    return nothing
end

# Upkeep
#
# The screen cannot be read back, so damage done by anything else writing to the
# terminal is undetectable: a program that resets the scrolling region or clears
# the screen leaves a footer that is simply gone, with nothing to notice it. The
# repair is to repaint blind, forcing the region back, since whatever clobbered
# the footer may have reset DECSTBM too.
#
# Doing that on a timer means writing to the terminal for ever, including all the
# time nothing is happening. Almost everything that can damage the footer arrives
# as something evaluated at the prompt: a shell command that clears the screen, a
# full screen program on its way out, output from a subprocess. The backend runs
# every expression through `ast_transforms`, so that is where the footer hears
# about it, and a prompt sitting idle is left alone.
#
# The slow floor covers what that misses: a task of the caller's own writing
# escape sequences, or another process sharing the terminal.

const UPKEEP_TICK = 0.5
const IDLE_REPAINT = 30.0
const EVAL_HOOKED = Ref(false)
# Starts set so the first tick paints, whatever brought the footer up.
const EVALUATED = Ref(true)

"""
    disturbed!()

Note that something which could have damaged the footer has happened, so that the
next upkeep tick repaints. Cheaper than [`refresh!`](@ref) for an event that
arrives often and does not need the screen right now.
"""
function disturbed!()
    EVALUATED[] = true
    return nothing
end

function install_eval_hook!()
    EVAL_HOOKED[] && return true
    isdefined(Base, :active_repl_backend) || return false
    backend = Base.active_repl_backend
    backend === nothing && return false
    hasproperty(backend, :ast_transforms) || return false
    # Applied with `invokelatest`, so a closure pushed from here is safe to call
    # from the backend task that was already running when it was made.
    push!(backend.ast_transforms, ast -> (disturbed!(); ast))
    EVAL_HOOKED[] = true
    return true
end

function upkeep(footer::Footer)
    healed = time()
    while true
        sleep(UPKEEP_TICK)
        install_eval_hook!()
        # The REPL extension can load after this task started, in a newer world.
        Base.invokelatest(__install_keys, nothing)
        footer.enabled || continue
        evaluated = EVALUATED[]
        evaluated && (EVALUATED[] = false)
        live = LIVE[]
        if evaluated || time() - healed >= IDLE_REPAINT
            Base.@lock footer.lock footer.stale = true
            notify(footer.wake)
            healed = time()
        elseif live !== nothing && Base.invokelatest(live)
            notify(footer.wake)
        end
    end
    return nothing
end

# Clearing the screen
#
# The REPL binds ^L to erasing the whole screen, which takes the footer with it:
# erase-in-display ignores the scrolling region, so the reserved rows go too, and a
# footer that nothing is currently updating would never be redrawn. What ^L is
# actually for is clearing the scrollback out of the way, so the replacement clears
# the scrolling region and leaves the reserved rows alone. Nothing is erased, so
# there is no flash to repair.
#
# Rebinding it needs the line editor, so it lives in the REPL extension and is
# reached through the two-layer dispatch REPLicant uses for its other REPL hooks.
# Called from upkeep until it takes, because the footer can be enabled from a
# startup file, before the REPL has built the keymaps this patches.

"""
    clear_screen_sequence()

Byte string that clears everything above the footer, leaving its rows alone.
"""
function clear_screen_sequence(footer::Footer = FOOTER)
    height, reserved = Base.@lock footer.lock begin
        (displaysize(footer.io)[1], footer.enabled ? footer.painted.rows : 0)
    end
    return clear_region_sequence(height, reserved)
end

__install_keys(::Any) = false

"""
    terminal_output(io)

Whether bytes written to `io` reach a terminal, and so whether escape sequences
sent there are a footer rather than corruption.

Julia's `stdout` is not always a `Base.TTY`. Anything that captures or forwards
output replaces it with a wrapper, so an unfamiliar type is resolved by asking
the operating system about the process's own output instead of being assumed.
"""
terminal_output(::IO) =
    @static Sys.iswindows() ? ccall(:_isatty, Cint, (Cint,), 1) == 1 :
    ccall(:isatty, Cint, (Cint,), 1) == 1
terminal_output(::Base.TTY) = true
terminal_output(::IOBuffer) = false
terminal_output(io::IOContext) = terminal_output(io.io)

"""
    enable!(; io = stdout)

Reserve the bottom of the terminal for the footer and start painting it. Returns
whether it did: with output piped or redirected to a file there is no terminal
to draw on, and the escape sequences would be corruption rather than a footer.
"""
function enable!(footer::Footer = FOOTER; io::IO = stdout)
    terminal_output(io) || return false
    start = Base.@lock footer.lock begin
        footer.io = io
        footer.enabled = true
        footer.stale = true
        was_started = footer.started
        footer.started = true
        !was_started
    end
    if start
        atexit(() -> disable!(footer))
        # These run for the life of the process once started, idling while the
        # footer is disabled. Stopping and restarting them per `enable!` left the
        # old ones winding down while the new ones were already painting.
        errormonitor(Threads.@spawn :interactive dispatch(footer))
        errormonitor(Threads.@spawn :interactive upkeep(footer))
        arm_resize_signal() &&
            errormonitor(Threads.@spawn :interactive watch_signal(footer))
    end
    # Straight away when there is already a REPL to bind, rather than leaving
    # Ctrl-L wiping the footer until upkeep next comes round.
    __install_keys(nothing)
    update!(footer)
    return true
end

"""
    disable!()

Give the reserved rows back to the scrolling region and stop painting.
"""
function disable!(footer::Footer = FOOTER)
    bytes = Base.@lock footer.lock begin
        if footer.enabled
            footer.enabled = false
            height, width = displaysize(footer.io)
            seq = paint(footer.painted.rows, String[], height, width; force_region = true)
            footer.painted = Painted()
            footer.stale = false
            seq
        else
            ""
        end
    end
    # Written here rather than left to the dispatch task, which idles from the
    # moment the footer is disabled and would never pick this up.
    isempty(bytes) || write(footer.io, bytes)
    return nothing
end

end # module Footers
