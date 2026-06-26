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

# The selection cascade: explicit port wins; else narrow to the deepest project
# that owns `project`, pick by --name or auto-select the lone server; finally fall
# back to a global name match.
function _resolve_port(port::Integer, project::AbstractString, name::AbstractString)
    port > 0 && return port

    live = _live_entries()
    isempty(live) && error("no running REPLicant servers found")

    target = _canonical(isempty(project) ? "." : project)

    owning = filter(live) do entry
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
            return scoped[index].port
        end
        length(scoped) == 1 && return scoped[1].port
        throw(
            _candidates_error(
                scoped,
                "multiple servers for $target, select one with --name or --port",
            ),
        )
    end

    if !isempty(name)
        named = filter(e -> e.name == name, live)
        length(named) == 1 && return named[1].port
        length(named) > 1 &&
            throw(_candidates_error(named, "multiple servers named \"$name\""))
    elseif length(live) == 1
        return live[1].port
    end

    throw(_candidates_error(live, "could not pick a server for $target"))
end

# Consume the value following a flag at `index`, erroring when the flag ends the
# argument list. Returns the value and the advanced index.
function _take_value(args, index, flag)
    index += 1
    index > length(args) && error("$flag needs a value")
    return args[index], index
end

function _parse_client_args(args)
    port = -1
    project = ""
    name = ""
    code = nothing
    index = 1
    while index <= length(args)
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
        elseif arg == "-e" || arg == "--eval"
            code, index = _take_value(args, index, "-e")
        else
            error("unrecognized argument: $arg")
        end
        index += 1
    end
    return (; port, project, name, code)
end

function _parse_port(value::AbstractString)
    port = tryparse(Int, value)
    isnothing(port) && error("invalid --port: $value")
    return port
end

# Write the result, terminating a non-empty payload with a newline so output does
# not run into the shell prompt. Tolerates a reader that closed early (e.g.
# `| head`): an EPIPE on a closed output pipe is the reader's choice, not a
# client error.
function _write_payload(io::IO, payload::AbstractString)
    try
        write(io, payload)
        isempty(payload) || endswith(payload, '\n') || write(io, '\n')
    catch error
        error isa Base.IOError || rethrow()
    end
    return nothing
end

# Send an eval frame and route the response: `ok` to `out`, `err` to `err`.
# Returns a process exit code, non-zero when the evaluation errored.
function _send(port::Integer, code::AbstractString; out::IO = stdout, err::IO = stderr)
    sock = Sockets.connect(Sockets.localhost, port)
    try
        _write_frame(sock, REQUEST_EVAL, code)
        frame = _read_frame(sock, RESPONSE_TYPES)
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

function _list_servers(out::IO = stdout)
    live = sort(_live_entries(); by = entry -> entry.port)
    _print_row(out, "PORT", "NAME", "PROJECT", "JULIA", "PID", "STARTED")
    for entry in live
        _print_row(
            out,
            string(entry.port),
            entry.name,
            entry.project,
            entry.julia,
            entry.pid,
            entry.started,
        )
    end
    return nothing
end

function _print_row(out, port, name, project, julia, pid, started)
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
        started,
    )
end

"""
    cli(args = ARGS; out = stdout, err = stderr) -> Int

Forwarding client entrypoint. With a leading `ls`/`list` it prints the live
servers; otherwise it resolves a target server and forwards code to it, taken
from `-e` or, when absent, from stdin. Returns a process exit code.
"""
function cli(args = ARGS; out::IO = stdout, err::IO = stderr)
    try
        if !isempty(args) && (args[1] == "ls" || args[1] == "list")
            _list_servers(out)
            return 0
        end
        parsed = _parse_client_args(args)
        code = isnothing(parsed.code) ? read(stdin, String) : parsed.code
        target = _resolve_port(parsed.port, parsed.project, parsed.name)
        return _send(target, code; out, err)
    catch error
        error isa InterruptException && rethrow()
        message = error isa ErrorException ? error.msg : sprint(showerror, error)
        println(err, "replicant: " * message)
        return 1
    end
end
