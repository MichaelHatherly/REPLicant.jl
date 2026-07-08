#
# Activity log.
#
# A shared REPLicant session is written to from two directions: the human typing at
# the `julia>` prompt and an agent evaluating over the socket, both into the same
# module. The agent has no view of what the human ran. This records both streams,
# with their captured output, into a bounded in-memory log the agent reads back with
# a `log` request.
#
# The log is process-global, like the output-routing streams (`REAL_OUT`,
# `ROUTING_INSTALLED`): it belongs to this Julia process's session, not to any one
# server, so several servers in the process read the same history. Reads never
# consume; each entry carries a monotonic `seq` so a client can ask for everything
# after a cursor without draining, and re-ask safely after a lost reply.

# One recorded evaluation. `source` is `:repl` (human-typed) or `:socket` (agent).
# `output` is the captured text, already byte-capped. `errored` drives nothing in the
# render; it marks a `:socket` eval that failed (its `ERROR:` text is already inside
# `output`) and is always false for `:repl` entries.
struct LogEntry
    seq::Int
    source::Symbol
    time::Dates.DateTime
    code::String
    output::String
    errored::Bool
end

# The human's currently-open entry. A REPL line's output arrives after the input
# expression, streamed through the `Router` write path, so the entry stays open and
# accumulates bytes until the next line's input finalizes it. `seq` is assigned when
# the entry opens, so a still-open entry already sorts and filters like a closed one.
mutable struct OpenEntry
    seq::Int
    time::Dates.DateTime
    code::String
    out::Vector{UInt8}
end

# One lock guards the ring, the open entry, and the sequence counter. The three
# writers (REPL backend task, worker eval task, dispatcher read) touch the log
# rarely, so contention is near zero; the tee's hot path skips the lock entirely with
# a nil-check before acquiring (see `_tee_human`).
const ACTIVITY_LOCK = ReentrantLock()
const ACTIVITY_LOG = LogEntry[]
const CURRENT_HUMAN_ENTRY = Ref{Union{OpenEntry, Nothing}}(nothing)
const ACTIVITY_SEQ = Ref(0)

const MAX_LOG_ENTRIES = 200
const MAX_ENTRY_OUTPUT_BYTES = 2048
const DEFAULT_LOG_ENTRIES = 15

# Next sequence number. Caller holds `ACTIVITY_LOCK`.
function _next_seq()
    ACTIVITY_SEQ[] += 1
    return ACTIVITY_SEQ[]
end

# Drop oldest entries past the cap. Caller holds `ACTIVITY_LOCK`.
function _evict!()
    while length(ACTIVITY_LOG) > MAX_LOG_ENTRIES
        popfirst!(ACTIVITY_LOG)
    end
    return nothing
end

# Truncate `s` to `MAX_ENTRY_OUTPUT_BYTES`, cutting on a character boundary so the
# stored string stays valid UTF-8. A chatty eval (an optimizer dumping thousands of
# iteration lines) is bounded here rather than flooding the agent's context.
function _cap(s::AbstractString)
    ncodeunits(s) <= MAX_ENTRY_OUTPUT_BYTES && return String(s)
    io = IOBuffer()
    for c in s
        position(io) + ncodeunits(c) > MAX_ENTRY_OUTPUT_BYTES && break
        print(io, c)
    end
    return String(take!(io)) * "\n[output truncated]"
end

# The open entry's bytes as a valid string. The tee caps by raw byte count and can
# split a multibyte character at the boundary, so trim back to the last valid prefix.
function _valid_prefix(bytes::Vector{UInt8})
    s = String(copy(bytes))
    isvalid(s) && return s
    n = length(bytes)
    while n > 0
        n -= 1
        s = String(bytes[1:n])
        isvalid(s) && return s
    end
    return ""
end

# Record an agent (`:socket`) evaluation: its code and rendered response body, the
# same text the client receives. Empty code (a bare `ping`-shaped body never reaches
# here) is skipped.
function _record_activity(source::Symbol, code::AbstractString, output::AbstractString, errored::Bool)
    isempty(strip(code)) && return nothing
    Base.@lock ACTIVITY_LOCK begin
        push!(ACTIVITY_LOG, LogEntry(_next_seq(), source, Dates.now(), String(code), _cap(output), errored))
        _evict!()
    end
    return nothing
end

# Open a fresh human entry, finalizing the previous one. Called from the REPL backend
# task by the input-capturing AST transform before the line evaluates; the line's
# output then streams into the new entry via the tee.
function _record_repl_input(code::AbstractString)
    Base.@lock ACTIVITY_LOCK begin
        _finalize_open!()
        isempty(strip(code)) && return nothing
        CURRENT_HUMAN_ENTRY[] = OpenEntry(_next_seq(), Dates.now(), String(code), UInt8[])
    end
    return nothing
end

# Freeze the open entry into the ring. Caller holds `ACTIVITY_LOCK`.
function _finalize_open!()
    entry = CURRENT_HUMAN_ENTRY[]
    entry === nothing && return nothing
    push!(ACTIVITY_LOG, LogEntry(entry.seq, :repl, entry.time, entry.code, _valid_prefix(entry.out), false))
    _evict!()
    CURRENT_HUMAN_ENTRY[] = nothing
    return nothing
end

# Append bytes to the open entry under the byte cap. Caller has already nil-checked
# `CURRENT_HUMAN_ENTRY[]` so the inactive path never reaches the lock; re-check inside
# since the entry can close between the check and the lock.
function _append_human!(bytes::AbstractVector{UInt8})
    Base.@lock ACTIVITY_LOCK begin
        entry = CURRENT_HUMAN_ENTRY[]
        entry === nothing && return nothing
        room = MAX_ENTRY_OUTPUT_BYTES - length(entry.out)
        room <= 0 && return nothing
        append!(entry.out, @view bytes[begin:(begin + min(length(bytes), room) - 1)])
    end
    return nothing
end

# Tee human terminal output into the open entry. Called from the `Router` write path
# for every unbound write, so the common case (no entry open, or logging never
# activated) must stay cheap: the nil-check returns before touching the lock. A
# background task the human spawned also writes unbound and bleeds into whichever
# entry is open; that mirrors the process-global fd 1/2 capture and is accepted as a
# rare, cosmetic interleaving.
function _tee_human(p::Ptr{UInt8}, n::UInt)
    CURRENT_HUMAN_ENTRY[] === nothing && return nothing
    return _append_human!(unsafe_wrap(Array, p, Int(n)))
end

function _tee_human(b::UInt8)
    CURRENT_HUMAN_ENTRY[] === nothing && return nothing
    return _append_human!(UInt8[b])
end

# Tee a displayed result value into the open entry. The REPL renders a bare
# expression's value through the display stack, not the redirected `stdout`, so the
# router's byte tee never sees it; `RouterDisplay` catches it here instead. Rendered
# the way the REPL renders it (limited, no color), with a trailing newline to match
# the terminal. Guarded on an open entry so idle sessions pay nothing.
function _tee_human_display(@nospecialize x)
    CURRENT_HUMAN_ENTRY[] === nothing && return nothing
    io = IOBuffer()
    try
        show(IOContext(io, :limit => true, :color => false), MIME"text/plain"(), x)
        write(io, '\n')
    catch  # dendro-ignore: empty_catch -- a display capture failure must not disturb the REPL
        return nothing
    end
    return _append_human!(take!(io))
end

# Parse a `log` request body: empty for the last `DEFAULT_LOG_ENTRIES`, a bare integer
# for the last N, or `since=<id>` for every entry past that sequence number.
function _parse_log_spec(spec::AbstractString)
    spec = strip(spec)
    isempty(spec) && return (; kind = :last, value = DEFAULT_LOG_ENTRIES)
    startswith(spec, "since=") &&
        return (; kind = :since, value = something(tryparse(Int, spec[7:end]), 0))
    return (; kind = :last, value = something(tryparse(Int, spec), DEFAULT_LOG_ENTRIES))
end

# Render recent activity for a `log` reply. Snapshots under the lock, including the
# still-open human entry so the agent sees the human's latest line even before the
# next prompt. Ordered by `seq`: a human entry that stayed open across an agent eval
# lands out of push order, so sort restores the sequence the numbers imply.
function _render_activity_log(spec::AbstractString)
    parsed = _parse_log_spec(spec)
    Base.@lock ACTIVITY_LOCK begin
        entries = copy(ACTIVITY_LOG)
        open = CURRENT_HUMAN_ENTRY[]
        open === nothing ||
            push!(entries, LogEntry(open.seq, :repl, open.time, open.code, _valid_prefix(open.out), false))
        sort!(entries; by = entry -> entry.seq)
        total = length(entries)
        window = if parsed.kind === :since
            filter(entry -> entry.seq > parsed.value, entries)
        else
            entries[(total - clamp(parsed.value, 0, total) + 1):total]
        end
        return _format_window(window, total)
    end
end

function _format_window(window::Vector{LogEntry}, total::Integer)
    io = IOBuffer()
    if isempty(window)
        print(io, "REPLicant activity — no matching entries ($total total)")
        return String(take!(io))
    end
    count = length(window)
    noun = count == 1 ? "entry" : "entries"
    println(io, "REPLicant activity — $count $noun (seq $(window[1].seq)-$(window[end].seq), $total total)")
    for entry in window
        println(io)
        _format_entry(io, entry)
    end
    return String(take!(io))
end

function _format_entry(io::IOBuffer, entry::LogEntry)
    println(io, "[#$(entry.seq) $(entry.source) $(Dates.format(entry.time, "HH:MM:SS"))] ", entry.code)
    isempty(entry.output) || println(io, rstrip(entry.output))
    return nothing
end

# Install the human-input capture once, at server start. Two-layer dispatch like
# `_revise`/`_notify_busy`: the REPL extension overrides `__install_activity_capture`
# to push the AST transform; the fallback no-ops, so a headless server (no REPL) never
# captures human input. Idempotent and process-wide.
const ACTIVITY_CAPTURE_INSTALLED = Ref(false)

function _install_activity_capture()
    ACTIVITY_CAPTURE_INSTALLED[] && return nothing
    ACTIVITY_CAPTURE_INSTALLED[] = true
    __install_activity_capture(nothing)
    return nothing
end
__install_activity_capture(::Any) = nothing
