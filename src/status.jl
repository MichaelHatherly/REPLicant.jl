#
# Footer content.
#
# What a shared session's owner wants at a glance: whether a server is up, which
# one it is, whether an agent is evaluating right now and for how long, and the
# last few things either side ran. The `Footers` submodule reserves the rows and
# draws them; everything here is the content it draws.
#
# Sections are functions of the terminal width, so both rows are re-rendered on
# every repaint against live state. That is what lets an elapsed time count up and
# a tail follow the log without anything having to push updates into the footer.

# Row colours. The status row is chrome and stays out of the way in grey; the
# state it reports is the part worth looking at, so that alone carries colour.
const DIM = "\e[90m"
const RESET = "\e[0m"
const IDLE_COLOR = "\e[32m"
const BUSY_COLOR = "\e[33m"
const ERROR_COLOR = "\e[31m"
const REPL_COLOR = "\e[35m"
const SOCKET_COLOR = "\e[36m"

_dim(text) = string(DIM, text, RESET)
_colored(color, text) = string(color, text, RESET)

# Compact enough to sit in a status row: seconds, then whole minutes, then hours
# and minutes. Always rounded down, so a duration never reads as one unit more
# than has actually elapsed.
function _duration(seconds::Real)
    seconds < 60 && return string(floor(Int, seconds), "s")
    minutes = floor(Int, seconds / 60)
    minutes < 60 && return string(minutes, "m")
    hours, rest = divrem(minutes, 60)
    return string(hours, "h", lpad(rest, 2, '0'), "m")
end

_elapsed(from::Dates.DateTime, now::Dates.DateTime) =
    _duration(Dates.value(now - from) / 1000)

# The status row's fields, in display order and labelled so that a narrow terminal
# can give the least pressing ones up by name rather than by position.
_status_fields(::Nothing, ::Dates.DateTime) =
    [:tag => _dim("REPLicant"), :state => _dim("no server")]

function _status_fields(srv::Server, now::Dates.DateTime)
    # Read once, then render. The server task fills the runtime details in when it
    # binds a port and the worker rewrites `busy_since` on every evaluation, so a
    # row built from several readings of the handle could describe two moments.
    port, project, started, busy = srv.port, srv.project, srv.started, srv.busy_since
    fields = [:tag => _dim("REPLicant")]
    isempty(srv.name) || push!(fields, :name => _dim(srv.name))
    isnothing(port) || push!(fields, :port => _dim(":$port"))
    isnothing(project) || push!(fields, :project => _dim(basename(project)))
    isnothing(started) || push!(fields, :uptime => _dim("up $(_elapsed(started, now))"))
    state = isnothing(busy) ? _colored(IDLE_COLOR, "idle") :
        _colored(BUSY_COLOR, "busy $(_elapsed(busy, now))")
    push!(fields, :state => state)
    return fields
end

# Fields are given up in this order when the row will not fit: context first, then
# identity, so what survives a narrow terminal is the state and the port that says
# which server it belongs to. Truncating instead would cut from the end, taking the
# state, which is the one field always worth a column.
const STATUS_GIVE_UP = (:project, :uptime, :tag, :name)

function _fit_status(fields, width::Integer)
    row() = join((text for (_, text) in fields), "  ")
    for key in STATUS_GIVE_UP
        Footers.display_width(row()) <= width && break
        filter!(pair -> first(pair) !== key, fields)
    end
    return row()
end

# The footer's status row for `srv` (or its absence) as of `now`, in `width`
# columns.
_render_status(srv::Union{Server, Nothing}, now::Dates.DateTime, width::Integer) =
    _fit_status(_status_fields(srv, now), width)

# One entry of the activity tail. Its first line only: the tail is a glance at what
# ran, so an entry is worth one row whatever it cost to type, and the ellipsis says
# there was more rather than letting a function definition eat the footer.
function _one_line(code::AbstractString)
    text = strip(code)
    stop = findfirst('\n', text)
    isnothing(stop) && return String(text)
    return string(rstrip(text[1:prevind(text, stop)]), " …")
end

function _activity_row(entry::LogEntry)
    seq = _colored(entry.errored ? ERROR_COLOR : DIM, "#$(entry.seq)")
    source = _colored(entry.source === :repl ? REPL_COLOR : SOCKET_COLOR, entry.source)
    time = _dim(Dates.format(entry.time, "HH:MM:SS"))
    return string(seq, " ", source, " ", time, "  ", _one_line(entry.code))
end

# The footer's activity tail: one row per entry, oldest first, so the newest sits
# closest to the prompt.
_render_activity(entries::AbstractVector{LogEntry}, ::Integer) =
    join((_activity_row(entry) for entry in entries), '\n')

# The footer draws on the real terminal rather than through the routing streams: a
# write to a router with no capture bound is taken for the human's own output and
# teed into the activity log, and a repaint is not that. The routers hold the
# stream they replaced, and both are the same terminal, so this is the right handle
# whether or not a server has installed them yet.
_terminal_stream() = ROUTING_INSTALLED[] ? REAL_OUT[] : stdout

# How many activity entries the tail shows. Held here rather than captured in the
# section, so the closure `footer!` installs is the same one whatever it is called
# with.
const FOOTER_ENTRIES = Ref(3)

"""
    footer!(on = true; entries = 3)

Pin a REPLicant status row to the bottom of the terminal, above `entries` rows of
recent activity. Returns whether the footer is now painting: with output piped or
redirected there is no terminal to draw on.

The status row reports the server running in this session (its label, port,
project, and uptime) and whether it is evaluating something right now, counting up
for as long as it is. The rows above it are the last few things the session ran,
from the prompt and over the socket alike, which is what a `log` request renders in
full.

    REPLicant.footer!()               # status and three rows of activity
    REPLicant.footer!(; entries = 0)  # the status row alone
    REPLicant.footer!(false)          # hand the rows back

The rows are taken out of the terminal's scrolling region rather than printed, so
the prompt keeps working throughout and ordinary output scrolls underneath. Call it
from `startup.jl` alongside the server, or at the prompt at any time.
"""
function footer!(on::Bool = true; entries::Integer = 3)
    if !on
        Footers.live!(nothing)
        Footers.disable!()
        return false
    end
    Footers.enable!(; io = _terminal_stream()) || return false
    FOOTER_ENTRIES[] = max(entries, 0)
    if FOOTER_ENTRIES[] == 0
        Footers.clear!(:activity)
    else
        Footers.set!(
            :activity,
            width -> _render_activity(_recent_activity(FOOTER_ENTRIES[]), width);
            rows = FOOTER_ENTRIES[],
        )
    end
    Footers.set!(:status, width -> _render_status(CURRENT_SERVER[], Dates.now(), width))
    # The elapsed time in the status row moves on its own, so the footer keeps
    # repainting for as long as an evaluation is in flight.
    Footers.live!(_is_busy)
    return true
end
