#
# Client.
#

# A registry entry as the selection cascade needs it. Parsed from the key=value
# files servers write, named by port in the registry directory.
struct RegistryEntry
    port::Int
    project::String
    name::String
    julia::String
    pid::String
    started::String
end

# Parse every registry file, skipping malformed ones (missing or non-numeric port).
function _read_entries()
    dir = _registry_dir()
    entries = RegistryEntry[]
    for fname in readdir(dir)
        path = joinpath(dir, fname)
        isfile(path) || continue
        fields = _parse_registry_entry(path)
        port = tryparse(Int, get(fields, "port", ""))
        isnothing(port) && continue
        push!(
            entries,
            RegistryEntry(
                port,
                get(fields, "project", ""),
                get(fields, "name", ""),
                get(fields, "julia", ""),
                get(fields, "pid", ""),
                get(fields, "started", ""),
            ),
        )
    end
    return entries
end

# Entries whose servers answer a ping, pruning the registry files of those that don't.
function _live_entries()
    live = RegistryEntry[]
    for entry in _read_entries()
        if _ping(entry.port)
            push!(live, entry)
        else
            rm(_registry_entry_path(entry.port); force = true)
        end
    end
    return live
end

# Build a selection error listing the candidate servers, showing --name for
# labeled ones and --port for the rest.
function _candidates_error(candidates, message::AbstractString)
    io = IOBuffer()
    println(io, "$message; candidates:")
    for entry in candidates
        if isempty(entry.name)
            println(io, "  --port=$(rpad(entry.port, 11)) $(entry.project) (unlabeled)")
        else
            println(
                io,
                "  --name=$(rpad(entry.name, 12)) port $(entry.port)  $(entry.project)",
            )
        end
    end
    return ErrorException(String(take!(io)))
end

# The selection cascade over `candidates`: narrow to the deepest project that owns
# `project`, pick by --name or auto-select the lone server; finally fall back to a
# global name match. Returns the chosen entry.
function _select_entry(
        candidates::Vector{RegistryEntry}, project::AbstractString, name::AbstractString,
    )
    isempty(candidates) && error("no running REPLicant servers found")

    target = _canonical(isempty(project) ? "." : project)

    owning = filter(candidates) do entry
        root = _canonical(entry.project)
        root == target || startswith(target, root * Base.Filesystem.path_separator)
    end
    if !isempty(owning)
        deepest = maximum(length(_canonical(e.project)) for e in owning)
        scoped = filter(e -> length(_canonical(e.project)) == deepest, owning)
        if !isempty(name)
            index = findfirst(e -> e.name == name, scoped)
            isnothing(index) &&
                throw(_candidates_error(scoped, "no server named \"$name\" for $target"))
            return scoped[index]
        end
        length(scoped) == 1 && return scoped[1]
        throw(
            _candidates_error(
                scoped,
                "multiple servers for $target, select one with --name or --port",
            ),
        )
    end

    if !isempty(name)
        named = filter(e -> e.name == name, candidates)
        length(named) == 1 && return named[1]
        length(named) > 1 &&
            throw(_candidates_error(named, "multiple servers named \"$name\""))
    elseif length(candidates) == 1
        return candidates[1]
    end

    throw(_candidates_error(candidates, "could not pick a server for $target"))
end

# Resolve an eval target to a port: an explicit port wins and connects directly;
# otherwise run the cascade over the live servers.
function _resolve_port(port::Integer, project::AbstractString, name::AbstractString)
    port > 0 && return port
    return _select_entry(_live_entries(), project, name).port
end

# Resolve a kill target to its registry entry. Unlike eval, this reads the raw
# registry without pinging, so a wedged server that cannot pong still resolves; an
# explicit port must name a registered server, since kill needs its pid.
function _kill_target(port::Integer, project::AbstractString, name::AbstractString)
    entries = _read_entries()
    if port > 0
        index = findfirst(e -> e.port == port, entries)
        isnothing(index) && error("no REPLicant server registered on port $port")
        return entries[index]
    end
    return _select_entry(entries, project, name)
end

# Consume the value following a flag at `index`, erroring when the flag ends the
# argument list. Returns the value and the advanced index.
function _take_value(args, index, flag)
    index += 1
    index > length(args) && error("$flag needs a value")
    return args[index], index
end

# Match a server selector (`--port`/`--project`/`--name`) at `index`, shared by the
# eval and kill parsers. Returns the updated selectors, the advanced index, and
# whether the flag matched, so each parser handles only its own extra flags.
function _match_selector(args, index, port, project, name)
    arg = args[index]
    if startswith(arg, "--port=")
        port = _parse_port(arg[(length("--port=") + 1):end])
    elseif arg == "--port"
        value, index = _take_value(args, index, "--port")
        port = _parse_port(value)
    elseif startswith(arg, "--project=")
        project = arg[(length("--project=") + 1):end]
    elseif arg == "--project"
        project, index = _take_value(args, index, "--project")
    elseif startswith(arg, "--name=")
        name = arg[(length("--name=") + 1):end]
    elseif arg == "--name"
        name, index = _take_value(args, index, "--name")
    else
        return port, project, name, index, false
    end
    return port, project, name, index, true
end

function _parse_client_args(args)
    port = -1
    project = ""
    name = ""
    code = nothing
    timeout = nothing
    index = 1
    while index <= length(args)
        port, project, name, index, matched = _match_selector(args, index, port, project, name)
        if !matched
            arg = args[index]
            if startswith(arg, "--timeout=")
                timeout = _parse_timeout(arg[(length("--timeout=") + 1):end])
            elseif arg == "--timeout"
                value, index = _take_value(args, index, "--timeout")
                timeout = _parse_timeout(value)
            elseif arg == "-e" || arg == "--eval"
                code, index = _take_value(args, index, "-e")
            else
                error("unrecognized argument: $arg")
            end
        end
        index += 1
    end
    return (; port, project, name, code, timeout)
end

function _parse_kill_args(args)
    port = -1
    project = ""
    name = ""
    force = false
    index = 1
    while index <= length(args)
        port, project, name, index, matched = _match_selector(args, index, port, project, name)
        if !matched
            arg = args[index]
            if arg == "--force" || arg == "-f"
                force = true
            else
                error("unrecognized argument: $arg")
            end
        end
        index += 1
    end
    return (; port, project, name, force)
end

function _parse_port(value::AbstractString)
    port = tryparse(Int, value)
    isnothing(port) && error("invalid --port: $value")
    return port
end

function _parse_timeout(value::AbstractString)
    seconds = tryparse(Float64, value)
    (isnothing(seconds) || seconds <= 0) && error("invalid --timeout: $value")
    return seconds
end

# Write the result, terminating a non-empty payload with a newline so output does
# not run into the shell prompt. Tolerates a reader that closed early (e.g.
# `| head`): an EPIPE on a closed output pipe is the reader's choice, not a
# client error.
function _write_payload(io::IO, payload::String)
    try
        write(io, payload)
        isempty(payload) || endswith(payload, '\n') || write(io, '\n')
    catch error
        error isa Base.IOError || rethrow()
    end
    return nothing
end

# Send an eval frame and route the response: `ok` to `out`, `err` to `err`.
# Returns a process exit code, non-zero when the evaluation errored. `timeout_seconds`
# bounds the wait for the result; `nothing` waits as long as the eval runs.
function _send(
        port::Integer, code::String;
        out::IO = stdout, err::IO = stderr, timeout_seconds = nothing,
    )
    sock = Sockets.connect(Sockets.localhost, port)
    try
        _write_frame(sock, REQUEST_EVAL, code)
        frame = try
            _read_frame(sock, RESPONSE_TYPES; timeout_seconds)
        catch timeout
            timeout isa ReadTimeout || rethrow()
            throw(
                ErrorException(
                    "evaluation did not respond within $(timeout.timeout_seconds)s; \
                    the server may be wedged on a long-running or non-returning eval. \
                    Recover with: julia +rpc kill",
                ),
            )
        end
        isnothing(frame) && error("server closed the connection without a response")
        if frame.type == RESPONSE_ERR
            _write_payload(err, frame.body)
            return 1
        end
        _write_payload(out, frame.body)
        return 0
    finally
        close(sock)
    end
end

# Render a pong body as a status: empty is idle, a timestamp is busy with elapsed
# seconds. A marker that does not parse still reads as busy rather than crashing.
function _format_status(marker::AbstractString)
    isempty(marker) && return "idle"
    since = tryparse(Dates.DateTime, marker)
    isnothing(since) && return "busy"
    seconds = max(0, round(Int, (Dates.now() - since).value / 1000))
    return "busy $(seconds)s"
end

function _list_servers(out::IO = stdout)
    rows = Tuple{RegistryEntry, String}[]
    for entry in _read_entries()
        status = _ping_status(entry.port)
        if isnothing(status)
            rm(_registry_entry_path(entry.port); force = true)
        else
            push!(rows, (entry, status))
        end
    end
    sort!(rows; by = row -> row[1].port)
    _print_row(out, "PORT", "NAME", "PROJECT", "JULIA", "PID", "STARTED", "STATUS")
    for (entry, status) in rows
        _print_row(
            out,
            string(entry.port),
            entry.name,
            entry.project,
            entry.julia,
            entry.pid,
            entry.started,
            _format_status(status),
        )
    end
    return nothing
end

function _print_row(
        out::IO, port::AbstractString, name::AbstractString, project::AbstractString,
        julia::AbstractString, pid::AbstractString, started::AbstractString,
        status::AbstractString,
    )
    return println(
        out,
        rpad(port, 6),
        "  ",
        rpad(name, 12),
        "  ",
        rpad(project, 30),
        "  ",
        rpad(julia, 8),
        "  ",
        rpad(pid, 7),
        "  ",
        rpad(started, 23),
        "  ",
        status,
    )
end

# Terminate a target server's process. Resolves from the raw registry so a wedged
# server still resolves, sends SIGTERM (SIGKILL with --force), and removes the
# registry entry, since a SIGKILL skips the server's own cleanup.
function _kill_server(args; out::IO = stdout)
    parsed = _parse_kill_args(args)
    entry = _kill_target(parsed.port, parsed.project, parsed.name)
    pid = tryparse(Int, entry.pid)
    isnothing(pid) && error("registry entry for port $(entry.port) has no valid pid")

    path = _registry_entry_path(entry.port)
    if !_process_alive(pid)
        rm(path; force = true)
        println(out, "REPLicant server on port $(entry.port) (pid $pid) was already gone")
        return 0
    end

    _signal_process(pid, parsed.force ? SIGKILL : SIGTERM)
    rm(path; force = true)
    action = parsed.force ? "killed" : "terminated"
    println(out, "$action REPLicant server on port $(entry.port) (pid $pid)")
    return 0
end

"""
    cli(args = ARGS; out = stdout, err = stderr) -> Int

Forwarding client entrypoint. A leading `ls`/`list` prints the live servers; a
leading `kill` terminates a resolved server (`--force` for SIGKILL). Otherwise it
resolves a target server and forwards code to it, taken from `-e` or, when absent,
from stdin. `--timeout <seconds>` bounds the wait for a result. Returns a process
exit code.
"""
function cli(args = ARGS; out::IO = stdout, err::IO = stderr)
    try
        if !isempty(args) && (args[1] == "ls" || args[1] == "list")
            _list_servers(out)
            return 0
        end
        if !isempty(args) && args[1] == "kill"
            return _kill_server(args[2:end]; out)
        end
        parsed = _parse_client_args(args)
        code = isnothing(parsed.code) ? read(stdin, String) : parsed.code
        target = _resolve_port(parsed.port, parsed.project, parsed.name)
        return _send(target, code; out, err, timeout_seconds = parsed.timeout)
    catch error
        error isa InterruptException && rethrow()
        message = error isa ErrorException ? error.msg : sprint(showerror, error)
        println(err, "replicant: " * message)
        return 1
    end
end
