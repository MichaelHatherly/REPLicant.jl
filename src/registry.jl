#
# Server registry.
#

# All live servers register here so clients discover them in one place,
# regardless of which project each server runs in. Entries carry each server's
# token, so the directory is owner-only. Windows gives each user its own temp dir.
function _registry_dir()
    dir = get(ENV, "REPLICANT_DIR", _default_registry_dir())
    @static if Sys.iswindows()
        mkpath(dir)
    else
        uid = Libc.getuid()
        mkpath(dir; mode = 0o700)
        # `lstat`: a symlink planted in a shared temp dir could point at a directory
        # of yours, pass the owner check, and be swapped before an entry is written.
        info = lstat(dir)
        islink(info) && error(
            "REPLicant registry $dir is a symlink; refusing to use it. Set REPLICANT_DIR to a directory you own.",
        )
        info.uid == uid || error(
            "REPLicant registry $dir is owned by another user; refusing to use it. Set REPLICANT_DIR to a directory you own.",
        )
        filemode(dir) & 0o077 == 0 || chmod(dir, 0o700)
    end
    return dir
end

@static if Sys.iswindows()
    _default_registry_dir() = joinpath(tempdir(), "replicant")
else
    # Per-user name, since a shared `/tmp` would let one user lock out the rest. `string`
    # the uid first: interpolating it prints through runtime dispatch, which the
    # image does not keep.
    _default_registry_dir() = joinpath(tempdir(), "replicant-" * string(Libc.getuid()))
end

_registry_entry_path(port::Integer) = joinpath(_registry_dir(), string(port))

function _registry_entry(
        port::Integer,
        project::AbstractString;
        token::AbstractString,
        name::AbstractString = "",
        started = Dates.now(),
    )
    entry = """
    port=$port
    project=$project
    token=$token
    pid=$(getpid())
    julia=$(VERSION)
    version=$(pkgversion(@__MODULE__))
    started=$started
    """
    isempty(name) || (entry *= "name=$name\n")
    return entry
end

# Every committed registry entry as `(path, fields)`. Skips the `<port>.tmp.<pid>`
# files an atomic write leaves in flight, and entries a concurrent prune or shutdown
# removes between listing and reading.
function _registry_entries()
    dir = _registry_dir()
    entries = Tuple{String, Dict{String, String}}[]
    for fname in readdir(dir)
        all(isdigit, fname) || continue
        path = joinpath(dir, fname)
        fields = _read_registry_entry(path)
        isnothing(fields) || push!(entries, (path, fields))
    end
    return entries
end

# The entry at `path`, or `nothing` when there is none: never written, or removed by
# a concurrent prune or shutdown before the read.
function _read_registry_entry(path::AbstractString)
    return try
        _parse_registry_entry(path)
    catch error
        (error isa SystemError && !isfile(path)) || rethrow()
        nothing
    end
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
        token::AbstractString,
        name::AbstractString = "",
        started = Dates.now(),
    )
    path = _registry_entry_path(port)
    temp = "$path.tmp.$(getpid())"
    try
        open(temp, "w") do io
            write(io, _registry_entry(port, project; token, name, started))
        end
        # `rename` replaces in one step. Before Julia 1.12, `mv(; force)` removes the
        # old entry first, so a concurrent reader could find none. Windows refuses to
        # replace a file another process has open, so there `mv` falls back to
        # removing it first, and readers tolerate the gap.
        @static if Sys.iswindows()
            mv(temp, path; force = true)
        else
            Base.Filesystem.rename(temp, path)
        end
    catch error
        isfile(temp) && rm(temp; force = true)
        rethrow(error)
    end
    return path
end

# The token the server on `port` registered, or empty when it has no entry. An
# empty token fails the server's check like any wrong one.
function _entry_token(port::Integer)
    fields = _read_registry_entry(_registry_entry_path(port))
    return isnothing(fields) ? "" : get(fields, "token", "")
end

# Probe a server with a ping frame. Returns the pong body (a busy-since marker,
# empty when idle) when the server answers, or `nothing` when it does not. A
# different-version server fails the version check and reads as dead, which is the
# intended lockstep behavior.
function _ping_status(port::Integer; timeout_seconds = PING_TIMEOUT_SECONDS)
    try
        sock = _open_request(port, REQUEST_PING, ""; timeout_seconds)
        try
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
# the only stop that lands on a worker wedged in a tight, non-yielding loop. libuv
# maps both, plus the signal-0 existence check, onto Windows, so the kill path is
# cross-platform.
const SIGTERM = 15
const SIGKILL = 9

# Liveness by process existence, independent of whether the server answers its
# socket. Signal 0 delivers nothing but still checks the target: a wedged server
# is a live process that cannot pong, so this is how `kill` finds its target.
_process_alive(pid::Integer) = _signal_process(pid, 0)

# Send `signal` to `pid` through libuv. Returns true when delivered, false when the
# process is already gone (`uv_kill` reports a negative UV error such as ESRCH).
_signal_process(pid::Integer, signal::Integer) =
    ccall(:uv_kill, Cint, (Cint, Cint), pid, signal) == 0

# Whether a server that missed its ping is gone rather than busy. A server wedged in
# a non-yielding eval on its only thread cannot pong, yet the kernel still accepts on
# its port; a dead one refuses, or its pid has exited. Checking both keeps a reused
# pid from passing for the server.
function _server_gone(port::Integer, pid::AbstractString)
    process = tryparse(Int, pid)
    return isnothing(process) || !_process_alive(process) || !_accepting(port)
end

function _accepting(port::Integer)
    try
        close(Sockets.connect(Sockets.localhost, port))
        return true
    catch
        return false
    end
end

# Drop registry entries for this project whose servers are gone. Replaces the old
# per-project lock: several live servers per project coexist.
function _prune_dead_entries(project::AbstractString)
    for (path, fields) in _registry_entries()
        get(fields, "project", nothing) == project || continue
        port = tryparse(Int, get(fields, "port", ""))
        isnothing(port) && continue
        _ping(port) && continue
        _server_gone(port, get(fields, "pid", "")) && rm(path; force = true)
    end
    return
end

# Return the port of a live server in `project` already labeled `name`, skipping
# our own `skip_port`. Pings only matching entries, so it stays cheap and never
# probes our own busy worker. `nothing` when the label is free.
function _label_conflict(project::AbstractString, name::AbstractString, skip_port::Integer)
    for (_, fields) in _registry_entries()
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
    label!(srv::Server, name::AbstractString) -> String

Label a REPLicant server so clients can select it with `--name`. Without a handle
it labels the server running in this process, the saved one when there is one.
Run it at the REPL, or send `REPLicant.label!("name")` over the eval channel so an
agent labels a server it reaches by `--port`. An empty `name` clears the label.

Errors when no server is running in this session, when `name` contains a newline,
or when another live server in the same project already holds `name`.
"""
function label!(name::AbstractString)
    srv = CURRENT_SERVER[]
    isnothing(srv) && error("No REPLicant server is running in this session to label.")
    return label!(srv, name)
end

@static if !CLIENT_ONLY
    function label!(srv::Server, name::AbstractString)
        occursin('\n', name) && error("REPLicant label must not contain a newline.")
        # A server has bound its port and published its details by the time a caller
        # holds a label-worthy handle; assert it to drop the `nothing` branch.
        port = srv.port::Int
        project = srv.project::String
        started = srv.started::Dates.DateTime
        # An empty name clears the label, and no server holds it.
        conflict = isempty(name) ? nothing : _label_conflict(project, name, port)
        isnothing(conflict) || error(
            "A REPLicant server in $project is already labeled \"$name\" (port $conflict).",
        )
        _write_registry_entry(port, project; srv.token, name, started)
        srv.name = name
        srv.verbose && @info "Labeled REPLicant server" port name
        return name
    end
end
