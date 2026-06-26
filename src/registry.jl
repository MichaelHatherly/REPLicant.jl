#
# Server registry.
#

# All live servers register here so clients discover them in one place,
# regardless of which project each server runs in.
function _registry_dir()
    dir = get(ENV, "REPLICANT_DIR", joinpath(tempdir(), "replicant"))
    mkpath(dir)
    return dir
end

_registry_entry_path(port::Integer) = joinpath(_registry_dir(), string(port))

function _registry_entry(
        port::Integer,
        project::AbstractString;
        name::AbstractString = "",
        started = Dates.now(),
    )
    entry = """
    port=$port
    project=$project
    pid=$(getpid())
    julia=$(VERSION)
    version=$(pkgversion(@__MODULE__))
    started=$started
    """
    isempty(name) || (entry *= "name=$name\n")
    return entry
end

function _parse_registry_entry(path::AbstractString)
    fields = Dict{String, String}()
    for line in eachline(path)
        isempty(strip(line)) && continue
        parts = split(line, '='; limit = 2)
        length(parts) == 2 || continue
        fields[parts[1]] = parts[2]
    end
    return fields
end

# Write atomically so clients never read a partial entry. The OS just handed
# us this port, so force-overwriting any stale same-port entry is correct.
function _write_registry_entry(
        port::Integer,
        project::AbstractString;
        name::AbstractString = "",
        started = Dates.now(),
    )
    path = _registry_entry_path(port)
    temp = "$path.tmp.$(getpid())"
    try
        open(temp, "w") do io
            write(io, _registry_entry(port, project; name, started))
        end
        mv(temp, path; force = true)
    catch error
        isfile(temp) && rm(temp; force = true)
        rethrow(error)
    end
    return path
end

# Probe a server with a ping frame. Returns the pong body (a busy-since marker,
# empty when idle) when the server answers, or `nothing` when it does not. A
# different-version server fails the version check and reads as dead, which is the
# intended lockstep behavior.
function _ping_status(port::Integer; timeout_seconds = PING_TIMEOUT_SECONDS)
    try
        sock = Sockets.connect(Sockets.localhost, port)
        try
            _write_frame(sock, REQUEST_PING, "")
            frame = _read_frame(sock, RESPONSE_TYPES; timeout_seconds)
            (isnothing(frame) || frame.type != RESPONSE_PONG) && return nothing
            return frame.body
        finally
            close(sock)
        end
    catch
        return nothing
    end
end

# Liveness as a boolean, for prune and resolution. Matches the check `ls` uses.
_ping(port::Integer; timeout_seconds = PING_TIMEOUT_SECONDS) =
    !isnothing(_ping_status(port; timeout_seconds))

# Signals for terminating a server process. SIGTERM asks; SIGKILL forces and is
# the only stop that lands on a worker wedged in a tight, non-yielding loop.
const SIGTERM = 15
const SIGKILL = 9

# Liveness by process existence, independent of whether the server answers its
# socket. Signal 0 delivers nothing but still checks the target: a wedged server
# is a live process that cannot pong, so this is how `kill` finds its target.
_process_alive(pid::Integer) = _signal_process(pid, 0)

# Send `signal` to `pid`. Returns true when delivered, false when the process is
# already gone (the `kill` syscall reports ESRCH).
_signal_process(pid::Integer, signal::Integer) =
    ccall(:kill, Cint, (Cint, Cint), pid, signal) == 0

# Drop registry entries for this project whose servers no longer answer a ping.
# Replaces the old per-project lock: several live servers per project coexist.
function _prune_dead_entries(project::AbstractString)
    dir = _registry_dir()
    for fname in readdir(dir)
        path = joinpath(dir, fname)
        isfile(path) || continue
        fields = _parse_registry_entry(path)
        get(fields, "project", nothing) == project || continue
        port = tryparse(Int, get(fields, "port", ""))
        isnothing(port) && continue
        _ping(port) || rm(path; force = true)
    end
    return
end

# Return the port of a live server in `project` already labeled `name`, skipping
# our own `skip_port`. Pings only matching entries, so it stays cheap and never
# probes our own busy worker. `nothing` when the label is free.
function _label_conflict(project::AbstractString, name::AbstractString, skip_port::Integer)
    dir = _registry_dir()
    for fname in readdir(dir)
        path = joinpath(dir, fname)
        isfile(path) || continue
        fields = _parse_registry_entry(path)
        get(fields, "project", nothing) == project || continue
        get(fields, "name", "") == name || continue
        port = tryparse(Int, get(fields, "port", ""))
        (isnothing(port) || port == skip_port) && continue
        _ping(port) && return port
    end
    return nothing
end

"""
    label!(name::AbstractString) -> String

Label the REPLicant server running in this process so clients can select it with
`--name`. Run it at the REPL, or send `REPLicant.label!("name")` over the eval
channel so an agent labels a server it reaches by `--port`.

Errors when no server is running in this session, when `name` contains a newline,
or when another live server in the same project already holds `name`.
"""
function label!(name::AbstractString)
    occursin('\n', name) && error("REPLicant label must not contain a newline.")
    srv = CURRENT_SERVER[]
    isnothing(srv) && error("No REPLicant server is running in this session to label.")
    # A recorded server has bound its port and published its details, so these
    # fields are set; assert it to drop the `nothing` branch from the union.
    port = srv.port::Int
    project = srv.project::String
    started = srv.started::Dates.DateTime
    conflict = _label_conflict(project, name, port)
    isnothing(conflict) || error(
        "A REPLicant server in $project is already labeled \"$name\" (port $conflict).",
    )
    _write_registry_entry(port, project; name, started)
    srv.name = name
    @info "Labeled REPLicant server" port name
    return name
end
