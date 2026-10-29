#
# Footer content.
#
# What a shared session's owner wants at a glance: whether a server is up, which
# one it is, and whether an agent is evaluating right now, for how long, and what.
# The `Footers` submodule reserves the row and draws it; everything here is the
# content it draws.
#
# The section is a function of the terminal width, so the row is re-rendered on
# every repaint against live state. That is what lets an elapsed time count up
# without anything having to push updates into the footer.

# Row colours. The status row is chrome and stays out of the way in grey; the
# state it reports is the part worth looking at, so that alone carries colour.
const DIM = "\e[90m"
const RESET = "\e[0m"
const IDLE_COLOR = "\e[32m"
const BUSY_COLOR = "\e[33m"

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
    code = srv.busy_code
    fields = [:tag => _dim("REPLicant")]
    isempty(srv.name) || push!(fields, :name => _dim(srv.name))
    isnothing(port) || push!(fields, :port => _dim(":$port"))
    isnothing(project) || push!(fields, :project => _dim(basename(project)))
    isnothing(started) || push!(fields, :uptime => _dim("up $(_elapsed(started, now))"))
    if isnothing(busy)
        push!(fields, :state => _colored(IDLE_COLOR, "idle"))
    else
        push!(fields, :state => _colored(BUSY_COLOR, "busy $(_elapsed(busy, now))"))
        push!(fields, :code => _one_line(code))
    end
    return fields
end

# Fields are given up in this order when the row will not fit: context first, then
# identity, so what survives a narrow terminal is the state and the port that says
# which server it belongs to. Truncating instead would cut from the end, taking the
# state, which is the one field always worth a column.
const STATUS_GIVE_UP = (:project, :uptime, :tag, :name)

function _fit_status(fields::Vector{Pair{Symbol, String}}, width::Integer)
    row() = join((text for (_, text) in fields), "  ")
    # The running code is last and the least pressing, so it takes whatever columns
    # the other fields leave, and is cut to them rather than costing any field.
    code = findfirst(pair -> first(pair) === :code, fields)
    if !isnothing(code)
        text = last(popat!(fields, code))
        room = width - Footers.display_width(row()) - 2
        room > 0 && push!(fields, :code => Footers.fit(text, room))
    end
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

# The running code's first line only: the status row has one line to give it, and
# the ellipsis says there was more.
function _one_line(code::AbstractString)
    text = strip(code)
    stop = findfirst('\n', text)
    isnothing(stop) && return String(text)
    return string(rstrip(text[1:prevind(text, stop)]), " …")
end

# The footer draws on the real terminal rather than through the routing streams: a
# write to a router with no capture bound is taken for the human's own output and
# teed into the activity log, and a repaint is not that. The routers hold the
# stream they replaced, and both are the same terminal, so this is the right handle
# whether or not a server has installed them yet.
_terminal_stream() = ROUTING_INSTALLED[] ? REAL_OUT[] : stdout

"""
    footer!(on = true)

Pin a REPLicant status row to the bottom of the terminal. Returns whether the
footer is now painting: with output piped or redirected there is no terminal to
draw on.

The row reports the server running in this session (its label, port, project, and
uptime) and whether it is evaluating something right now. While it is, the row
counts up the elapsed time and shows the first line of the code being run. The full
history of what ran is what `julia +rpc log` renders.

    REPLicant.footer!()       # pin the status row
    REPLicant.footer!(false)  # hand the row back

The row is taken out of the terminal's scrolling region rather than printed, so
the prompt keeps working throughout and ordinary output scrolls underneath. Call it
from `startup.jl` alongside the server, or at the prompt at any time.
"""
# The server the footer reports: the one current when it was enabled, so servers
# started later in the process (a test suite's) never take the row over. Once that
# server stops, whichever is current.
_footer_target(session) =
    isnothing(session) || istaskdone(session.task) ? CURRENT_SERVER[] : session

function footer!(on::Bool = true)
    if !on
        Footers.live!(nothing)
        Footers.disable!()
        return false
    end
    Footers.enable!(; io = _terminal_stream()) || return false
    session = CURRENT_SERVER[]
    Footers.set!(:status, width -> _render_status(_footer_target(session), Dates.now(), width))
    # The elapsed time in the status row moves on its own, so the footer keeps
    # repainting for as long as an evaluation is in flight.
    Footers.live!(_is_busy)
    return true
end
