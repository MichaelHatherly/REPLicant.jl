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

# Warn that no server owns the caller's location, so a server rooted at another
# project was selected. Returns the entry so callers can `return _warn_foreign(...)`.
# Goes to `err` so it never corrupts a result parsed from stdout.
function _warn_foreign(err::IO, entry::RegistryEntry, target::AbstractString)
    println(err, "replicant: no server for $target; using server in $(entry.project)")
    return entry
end

# The selection cascade over `candidates`: narrow to the deepest project that owns
# `project`, pick by --name or auto-select the lone server; finally fall back to a
# global name match. Returns the chosen entry. A fallback to a server outside the
# caller's project warns on `err`.
function _select_entry(
        candidates::Vector{RegistryEntry}, project::AbstractString, name::AbstractString;
        err::IO = stderr,
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
        length(named) == 1 && return _warn_foreign(err, named[1], target)
        length(named) > 1 &&
            throw(_candidates_error(named, "multiple servers named \"$name\""))
    elseif length(candidates) == 1
        return _warn_foreign(err, candidates[1], target)
    end

    throw(_candidates_error(candidates, "could not pick a server for $target"))
end

# Resolve an eval target to a port: an explicit port wins and connects directly;
# otherwise run the cascade over the live servers.
function _resolve_port(
        port::Integer, project::AbstractString, name::AbstractString; err::IO = stderr,
    )
    port > 0 && return port
    return _select_entry(_live_entries(), project, name; err).port
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
function _take_value(args::Vector{String}, index, flag)
    index += 1
    index > length(args) && error("$flag needs a value")
    return args[index], index
end

# Flags that carry a value, as `--flag value` or `--flag=value`. `-e`/`--eval` are
# aliases for the code to run.
const VALUED_FLAGS =
    ("--port", "--project", "--name", "--timeout", "--dir", "--module", "-e", "--eval")
# Flags that stand alone. `-f` is an alias for `--force`.
const BARE_FLAGS = ("--force", "-f")

# The valued flag `arg` names, whether written `--flag` or `--flag=value`, else
# nothing. Centralizes the dual-form match so each flag is handled in one place.
function _valued_flag(arg)
    for flag in VALUED_FLAGS
        (arg == flag || startswith(arg, flag * "=")) && return flag
    end
    return nothing
end

# Split args into a flag-to-value map and the set of bare flags present, accepting
# both `--flag value` and `--flag=value`. A positional `.jl` path is a script to run:
# it and every following argument (taken verbatim as the script's `ARGS`) end flag
# parsing, mirroring `julia [opts] script.jl [args]`. Other unknown arguments error.
function _tokenize_args(args::Vector{String})
    values = Dict{String, String}()
    bare = Set{String}()
    file = nothing
    script_args = String[]
    index = 1
    while index <= length(args)
        arg = args[index]
        flag = _valued_flag(arg)
        if !isnothing(flag)
            if arg == flag
                value, index = _take_value(args, index, flag)
                values[flag] = value
            else
                values[flag] = arg[(length(flag) + 2):end]
            end
        elseif arg in BARE_FLAGS
            push!(bare, arg)
        elseif endswith(arg, ".jl")
            file = arg
            script_args = args[(index + 1):end]
            break
        else
            error("unrecognized argument: $arg")
        end
        index += 1
    end
    return values, bare, file, script_args
end

# Parse the client's arguments into selectors plus the per-mode flags. One parser
# serves both paths: eval reads `code`/`timeout`, kill reads `force`. A flag for the
# other mode is harmless: each caller reads only the fields it acts on.
function _parse_args(args::Vector{String})
    values, bare, file, script_args = _tokenize_args(args)
    port = haskey(values, "--port") ? _parse_port(values["--port"]) : -1
    timeout = haskey(values, "--timeout") ? _parse_timeout(values["--timeout"]) : nothing
    code = get(values, "-e", get(values, "--eval", nothing))
    isnothing(file) ||
        isnothing(code) ||
        error("cannot combine a script file with -e/--eval")
    return (;
        port,
        project = get(values, "--project", ""),
        name = get(values, "--name", ""),
        dir = get(values, "--dir", ""),
        mod = get(values, "--module", ""),
        code,
        file,
        script_args,
        timeout,
        force = !isempty(bare),
    )
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

# Build the code that runs a script file in the warm session. The absolute path is
# forwarded so the server, sharing the filesystem, reaches the file whatever its
# cwd, and `include` runs it so stack frames carry the real filename and the
# script's definitions persist in the session. `ARGS` holds the script's arguments
# for the run, then is restored from task-local storage so the session's `ARGS` is
# unchanged afterward and nothing leaks into it.
function _script_code(file::String, script_args::Vector{String})
    path = abspath(file)
    isfile(path) || error("file not found: $file")
    return """
    task_local_storage(:replicant_saved_args, copy(ARGS))
    empty!(ARGS); append!(ARGS, $(repr(script_args)))
    try
        include($(repr(path)))
    finally
        empty!(ARGS); append!(ARGS, task_local_storage(:replicant_saved_args))
    end"""
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
        cwd::AbstractString = "", mod::AbstractString = "",
    )
    sock = Sockets.connect(Sockets.localhost, port)
    try
        _write_frame(sock, REQUEST_EVAL, _encode_eval_body(; cwd, mod, code))
        frame = try
            _read_frame(sock, RESPONSE_TYPES; timeout_seconds)
        catch timeout
            timeout isa ReadTimeout || rethrow()
            throw(
                ErrorException(
                    "evaluation did not respond within $(timeout.timeout_seconds)s; \
                    the eval is still running on the server. Free it with: \
                    julia +rpc interrupt (or julia +rpc kill to stop the process).",
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
function _kill_server(args::Vector{String}; out::IO = stdout)
    parsed = _parse_args(args)
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

# Start a server in a detached Julia process so it outlives this client. Roots it
# at `--dir` (default the caller's directory) and `--project` (default `@.`, the
# project of that directory), optionally labels it with `--name`, then waits for it
# to register before reporting the port. Stop it later with `julia +rpc kill`.
function _start_server(args::Vector{String}; out::IO = stdout)
    parsed = _parse_args(args)
    dir = isempty(parsed.dir) ? pwd() : abspath(parsed.dir)
    isdir(dir) || error("directory not found: $dir")
    project = isempty(parsed.project) ? "@." : parsed.project

    # The detached server runs the same recipe an interactive session does: start,
    # wait for the port, optionally label, then block on the server task forever.
    label = isempty(parsed.name) ? "" : "REPLicant.label!($(repr(parsed.name))); "
    script = "using REPLicant; s = REPLicant.Server(save = true); take!(s.channel); $(label)wait(s.task)"

    before = Set(entry.port for entry in _read_entries())
    command = Cmd(
        `$(Base.julia_cmd()) --project=$project --startup-file=no -e $script`;
        detach = true,
        dir,
    )
    process =
        run(pipeline(command; stdin = devnull, stdout = devnull, stderr = devnull); wait = false)

    entry = _await_entry(dir, before, process)
    println(out, "started REPLicant server on port $(entry.port) for $(entry.project)")
    return 0
end

# Wait for a newly started server to register: a live entry, rooted at `dir`'s
# project, whose port was not already present in `before`. Fails fast when the
# spawned process exits before registering (e.g. REPLicant missing from the env).
function _await_entry(dir::AbstractString, before::Set{Int}, process; timeout = 60)
    root = _project_root(dir)
    deadline = time() + timeout
    while time() < deadline
        for entry in _read_entries()
            entry.port in before && continue
            _canonical(entry.project) == root || continue
            _ping(entry.port) && return entry
        end
        Base.process_exited(process) && error(
            "the server process exited before registering; \
            check that REPLicant is installed for $root",
        )
        sleep(0.1)
    end
    return error("server did not register within $(timeout)s")
end

# Reset a named session to a clean module without restarting the process. Resolves
# a live server and sends a reset frame carrying the module name. The default
# session is the process's `Main` and cannot be reset, so `--module` is required.
function _reset_server(args::Vector{String}; out::IO = stdout, err::IO = stderr)
    parsed = _parse_args(args)
    isempty(parsed.mod) &&
        error("reset needs --module <name>; the default session cannot be reset")
    target = _resolve_port(parsed.port, parsed.project, parsed.name; err)
    sock = Sockets.connect(Sockets.localhost, target)
    try
        _write_frame(sock, REQUEST_RESET, parsed.mod)
        frame = _read_frame(sock, RESPONSE_TYPES; timeout_seconds = PING_TIMEOUT_SECONDS)
        isnothing(frame) && error("server closed the connection without a response")
        println(out, "REPLicant server on port $target: $(frame.body)")
        return 0
    finally
        close(sock)
    end
end

# Free a server wedged on a running eval without killing the process. Resolves a
# live server (the soft tier needs a healthy dispatcher to receive the request, so
# live resolution gives a clean "no servers" error rather than a hang), schedules an
# `InterruptException` onto the running eval, and reports the outcome.
function _interrupt_server(args::Vector{String}; out::IO = stdout)
    parsed = _parse_args(args)
    target = _resolve_port(parsed.port, parsed.project, parsed.name)
    sock = Sockets.connect(Sockets.localhost, target)
    try
        _write_frame(sock, REQUEST_INTERRUPT, "")
        frame = _read_frame(sock, RESPONSE_TYPES; timeout_seconds = PING_TIMEOUT_SECONDS)
        isnothing(frame) && error("server closed the connection without a response")
        println(out, "REPLicant server on port $target: $(frame.body)")
        return 0
    finally
        close(sock)
    end
end

"""
    cli(args = ARGS; out = stdout, err = stderr) -> Int

Forwarding client entrypoint. A leading `ls`/`list` prints the live servers; a
leading `start` launches a detached server (`--dir`/`--project`/`--name`); a
leading `kill` terminates a resolved server (`--force` for SIGKILL); a leading
`interrupt` frees a server wedged on a running eval, scheduling an
`InterruptException` onto it without killing the process (`kill` stays the hard
tier); a leading `reset` clears a named session (`--module`). Otherwise it resolves
a target server and forwards code to it, taken from `-e`, from a leading `script.jl`
positional run with `include` (trailing positionals become the script's `ARGS`),
or, when neither is given, from stdin. The eval runs in the caller's directory
(override with `--dir`) and in the default session unless `--module <name>` selects
one. `--timeout <seconds>` bounds the wait for a result. Returns a process exit code.
"""
# Run a leading subcommand (`ls`/`start`/`kill`/`interrupt`/`reset`) and return its
# exit code, or `nothing` when `args` does not start with one, so `cli` falls
# through to evaluation.
function _run_subcommand(args::Vector{String}, out::IO, err::IO)
    isempty(args) && return nothing
    command, rest = args[1], args[2:end]
    command in ("ls", "list") && return (_list_servers(out); 0)
    command == "start" && return _start_server(rest; out)
    command == "kill" && return _kill_server(rest; out)
    command == "interrupt" && return _interrupt_server(rest; out)
    command == "reset" && return _reset_server(rest; out, err)
    return nothing
end

function cli(args::Vector{String} = ARGS; out::IO = stdout, err::IO = stderr)
    try
        handled = _run_subcommand(args, out, err)
        isnothing(handled) || return handled

        parsed = _parse_args(args)
        file = parsed.file
        code = if !isnothing(file)
            _script_code(file, parsed.script_args)
        elseif isnothing(parsed.code)
            read(stdin, String)
        else
            parsed.code
        end
        # Run the eval in the caller's directory by default so relative paths
        # resolve where the agent invoked the client, not where the server started.
        cwd = isempty(parsed.dir) ? pwd() : abspath(parsed.dir)
        target = _resolve_port(parsed.port, parsed.project, parsed.name; err)
        return _send(target, code; out, err, timeout_seconds = parsed.timeout, cwd, mod = parsed.mod)
    catch error
        error isa InterruptException && rethrow()
        message = error isa ErrorException ? error.msg : sprint(showerror, error)
        println(err, "replicant: " * message)
        return 1
    end
end
