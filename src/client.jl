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
function _candidates_error(candidates::Vector{RegistryEntry}, message::AbstractString)
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

# Warn that the server selected by an explicit `--name` is rooted at another
# project than the caller's location. Returns the entry so callers can
# `return _warn_foreign(...)`. Goes to `err` so it never corrupts a result parsed
# from stdout.
function _warn_foreign(err::IO, entry::RegistryEntry, target::AbstractString)
    println(err, "replicant: no server for $target; falling back to the server in $(entry.project)")
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
    end

    # No server owns the caller's location and no explicit selector was given.
    # Refuse rather than silently evaluating against an unrelated project; an
    # explicit --port/--project/--name targets a foreign server on purpose.
    throw(
        _candidates_error(
            candidates, "no server owns $target; select one with --port/--project/--name",
        ),
    )
end

# Resolve an eval target to a port: an explicit port wins and connects directly;
# otherwise run the cascade over the live servers.
function _resolve_port(
        port::Integer, project::AbstractString, name::AbstractString; err::IO = stderr,
    )
    if port > 0
        _ping(port) || error("no REPLicant server responding on port $port")
        return port
    end
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
const VALUED_FLAGS = (
    "--port", "--project", "--name", "--timeout", "--dir", "--module", "--channel",
    "-e", "--eval",
)
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
            error("unrecognized argument: $arg; run `julia +rpc help` for usage")
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
        channel = get(values, "--channel", ""),
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

# The Julia launcher for a started server: `julia` on PATH (the default channel), or
# `julia +<channel>` for a specific version. Using the launcher rather than
# `Base.julia_cmd()` keeps the client's own flags (its `--startup-file=no`, sysimage,
# optimization) from forwarding, so the server runs the channel's normal defaults.
# The `rpc` channel already requires juliaup, so `julia` on PATH is its launcher.
_server_julia(channel::AbstractString) = isempty(channel) ? `julia` : `julia +$channel`

# The exact Julia version `channel` resolves to, via the launcher's `--version`
# (cheap: a juliaup/Julia startup with no project or package loading). `nothing`
# when the launcher cannot be run (e.g. an uninstalled channel), so `start` can
# still attempt it and surface that failure itself rather than this probe's. `channel`
# is concrete `String` (not `AbstractString`): this is private plumbing always fed
# `_parse_args`'s `String`-typed `channel` field, never a general-purpose entry
# point, so there is no genericity to preserve and a concrete signature keeps JET
# sound mode from flagging every call inside as unresolvable dynamic dispatch.
function _channel_julia_version(channel::String)
    out = try
        read(`$(_server_julia(channel)) --version`, String)
    catch
        return nothing
    end
    m = match(r"(\d+\.\d+\.\d+)", out)
    isnothing(m) && return nothing
    capture = m.captures[1]
    return isnothing(capture) ? nothing : String(capture)
end

# Refuse to start when an explicit `channel` is pinned to a different Julia minor
# version than the target environment's Manifest.toml. Starting anyway activates
# that Manifest.toml under a Julia it was never resolved for, which leaves Julia
# silently rebuilding the whole environment's precompile cache before the server
# can even register -- easily enough to run past `_await_entry`'s timeout and
# look like a hang rather than the version mismatch it is. Compares major.minor
# only: a patch difference does not force that rebuild.
#
# Only checked when `channel` is explicit. With no `channel`, the launcher
# (juliaup's `julia`) already resolves a channel matching the active project's
# manifest on its own -- confirmed by `julia --project=<dir>` reporting the
# manifest's pinned version even though plain `julia --version` reports the
# default channel. An explicit `+channel` is what skips that resolution and
# forces the mismatch, so that's the only case worth guarding.
#
# Skipped for an `@`-prefixed `project` other than `@.` (a named or shared
# environment, not a project-specific manifest this can mismatch against), and
# silently skipped whenever the manifest's version cannot be determined or
# parsed. Only `@.` searches ancestors; an explicit `project` names exactly the
# environment Julia will activate, so only that path is checked, resolved
# against `dir` (the server's working directory) when relative. Concrete
# `String` arguments for the same reason as `_channel_julia_version`: this is
# `_start_server`'s private pre-flight check, always called with its own
# already-`String` `dir`/`project`/`channel` locals. `manifest_version_of`/
# `channel_version_of` default to the real (subprocess-backed) lookups; tests
# inject stubs so the version-comparison logic runs without needing a second
# Julia channel actually installed (CI's matrix installs exactly one per job).
# The `::Union{Nothing, String}` assertions narrow the abstract `Function`
# callable's result back to a concrete type for everything downstream.
function _check_julia_version(
        dir::String, project::String, channel::String;
        manifest_version_of::Function = _manifest_julia_version,
        channel_version_of::Function = _channel_julia_version,
    )
    isempty(channel) && return nothing
    walk = project == "@."
    search_dir = if walk
        dir
    elseif startswith(project, "@")
        return nothing
    else
        path = abspath(dir, project)
        isdir(path) ? path : dirname(path)
    end
    manifest_version = manifest_version_of(search_dir, walk)::Union{Nothing, String}
    isnothing(manifest_version) && return nothing
    channel_version = channel_version_of(channel)::Union{Nothing, String}
    isnothing(channel_version) && return nothing
    function _minor(v::String)
        m = match(r"^(\d+\.\d+)", v)
        return isnothing(m) ? nothing : m.captures[1]
    end
    manifest_minor = _minor(manifest_version)
    channel_minor = _minor(channel_version)
    (isnothing(manifest_minor) || isnothing(channel_minor)) && return nothing
    manifest_minor == channel_minor && return nothing

    error(
        "Manifest.toml at $search_dir is pinned to Julia $manifest_version, but " *
            "julia +$channel resolves to $channel_version. Resolve the manifest under that " *
            "version (julia +$channel --project=$search_dir -e 'using Pkg; Pkg.resolve()') " *
            "or start on the channel that matches the manifest.",
    )
end

# Start a server in a detached Julia process so it outlives this client. Roots it
# at `--dir` (default the caller's directory) and `--project` (default `@.`, the
# project of that directory), runs on `--channel` (default the launcher's default
# version), optionally labels it with `--name`, then waits for it to register before
# reporting the port. Stop it later with `julia +rpc kill`.
function _start_server(args::Vector{String}; out::IO = stdout)
    parsed = _parse_args(args)
    dir = isempty(parsed.dir) ? pwd() : abspath(parsed.dir)
    isdir(dir) || error("directory not found: $dir")
    project = isempty(parsed.project) ? "@." : parsed.project
    root = _project_root(dir)

    _check_julia_version(dir, project, parsed.channel)

    # Refuse a name a live server in the target project already holds, so a conflict
    # fails here with a clear error rather than silently killing the detached process
    # when its own `label!` throws after it has already registered.
    if !isempty(parsed.name)
        conflict = _label_conflict(root, parsed.name, 0)
        isnothing(conflict) || error(
            "a REPLicant server in $root is already labeled \"$(parsed.name)\" (port $conflict)",
        )
    end

    # The detached server runs the same recipe an interactive session does: start,
    # wait for the port, optionally label, then block on the server task forever.
    label = isempty(parsed.name) ? "" : "REPLicant.label!($(repr(parsed.name))); "
    script = "using REPLicant; s = REPLicant.Server(save = true); take!(s.channel); $(label)wait(s.task)"

    # Snapshot the live servers (pruning dead ones) so the new entry is identified as
    # the one that appears for this project afterward, even across a reused port.
    before = Set(entry.port for entry in _live_entries())

    # Capture the detached server's stderr so a startup failure (REPLicant missing,
    # a precompile error) surfaces in the error instead of vanishing into devnull.
    # The server keeps logging there for its lifetime, like any daemon's log. No
    # `--startup-file=no`: the server is a warm session, so it loads the user's
    # startup.jl (Revise and other REPL setup), unlike a one-off client eval.
    log = tempname()
    command = Cmd(
        `$(_server_julia(parsed.channel)) --project=$project -e $script`;
        detach = true,
        dir,
    )
    process =
        run(pipeline(command; stdin = devnull, stdout = devnull, stderr = log); wait = false)

    entry = _await_entry(root, before, process, log)
    println(out, "started REPLicant server on port $(entry.port) for $(entry.project) (log: $log)")
    return 0
end

# The captured stderr of a failed start, for the error message; empty when the log
# has nothing.
function _start_log(log::AbstractString)
    (isfile(log) && !isempty(read(log, String))) || return ""
    return "; server stderr:\n" * read(log, String)
end

# Wait for the spawned server to register: a live entry rooted at `root` whose port
# is new since `before`. Matching the entry rather than the spawned process's pid is
# what works when `julia` is a launcher (the juliaup shim, or a detached PATH spawn
# on Windows) that runs the server as a child with a different pid. Fails fast when
# the process exits before registering, surfacing its captured stderr. The timeout is
# generous because a first start on a channel where REPLicant is not yet precompiled
# builds its package image before the server can register.
function _await_entry(root::AbstractString, before::Set{Int}, process, log::AbstractString; timeout = 180)
    deadline = time() + timeout
    while time() < deadline
        for entry in _read_entries()
            entry.port in before && continue
            _canonical(entry.project) == root || continue
            _ping(entry.port) && return entry
        end
        Base.process_exited(process) &&
            error("the server process exited before registering$(_start_log(log))")
        sleep(0.1)
    end
    return error("server did not register within $(timeout)s$(_start_log(log))")
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
        if frame.type == RESPONSE_ERR
            println(err, "replicant: $(frame.body)")
            return 1
        end
        println(out, "REPLicant server on port $target: $(frame.body)")
        return 0
    finally
        close(sock)
    end
end

# Poll a server until it reports idle, or the budget elapses. Pings are answered
# off the worker queue, so a busy worker still pongs (an empty marker means idle).
# Returns whether the server reached idle.
function _await_idle(port::Integer; timeout = 2.0)
    deadline = time() + timeout
    while time() < deadline
        _ping_status(port) == "" && return true
        sleep(0.05)
    end
    return false
end

# Free a server wedged on a running eval without killing the process. Resolves a
# live server (the soft tier needs a healthy dispatcher to receive the request, so
# live resolution gives a clean "no servers" error rather than a hang), schedules an
# `InterruptException` onto the running eval, then confirms it stopped. The signal
# lands only when the eval yields, so a tight non-yielding loop stays busy: report
# that and point at `kill --force` rather than claim a success that did not happen.
function _interrupt_server(args::Vector{String}; out::IO = stdout, err::IO = stderr)
    parsed = _parse_args(args)
    target = _resolve_port(parsed.port, parsed.project, parsed.name)
    sock = Sockets.connect(Sockets.localhost, target)
    body = try
        _write_frame(sock, REQUEST_INTERRUPT, "")
        frame = _read_frame(sock, RESPONSE_TYPES; timeout_seconds = PING_TIMEOUT_SECONDS)
        isnothing(frame) && error("server closed the connection without a response")
        frame.body
    finally
        close(sock)
    end

    if body != "interrupted"
        # Nothing was running (e.g. "no evaluation running"); report it as-is.
        println(out, "REPLicant server on port $target: $body")
        return 0
    end
    if _await_idle(target)
        println(out, "REPLicant server on port $target: interrupted, now idle")
        return 0
    end
    println(
        err,
        "replicant: interrupt sent to the server on port $target, but the eval is still \
        running (not yielding); stop it with: julia +rpc kill --force",
    )
    return 1
end

"""
    cli(args = ARGS; out = stdout, err = stderr) -> Int

Forwarding client entrypoint. A leading `ls`/`list` prints the live servers; a
leading `start` launches a detached server (`--dir`/`--project`/`--name`/`--channel`); a
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
# Usage text for `help`/`--help`/`-h`, listing the subcommands, selectors, and the
# per-mode flags so an agent can discover the surface without reading the skill.
const USAGE = """
julia +rpc — forward Julia code to a warm REPLicant server

Usage:
  julia +rpc [selectors] -e <code>     evaluate code (also via heredoc/stdin, or a script.jl)
  julia +rpc ls                        list live servers
  julia +rpc start [start-options]     start a detached server
  julia +rpc kill [selectors] [-f]     stop a server (-f/--force sends SIGKILL)
  julia +rpc interrupt [selectors]     free a server wedged on a running eval
  julia +rpc reset --module <name>     clear a named session
  julia +rpc help                      show this message

Selectors:
  --port <n>         target a specific port
  --name <label>     target a labeled server
  --project <path>   select by project root (default: current directory)

Eval options:
  -e, --eval <code>  code to run (else read stdin, or run a positional script.jl)
  --dir <path>       working directory for the eval (default: caller's cwd)
  --module <name>    evaluate into a named session, isolated from the default
  --timeout <secs>   bound the wait for a result

Start options:
  --dir <path>       directory to serve (default: current directory)
  --project <path>   Julia environment to activate (default: the project of --dir)
  --name <label>     label the server
  --channel <ver>    juliaup channel to run the server on (default: your default)
"""

_usage(out::IO) = (print(out, USAGE); 0)

# Run a leading subcommand (`ls`/`start`/`kill`/`interrupt`/`reset`/`help`) and
# return its exit code, or `nothing` when `args` does not start with one, so `cli`
# falls through to evaluation.
function _run_subcommand(args::Vector{String}, out::IO, err::IO)
    isempty(args) && return nothing
    command, rest = args[1], args[2:end]
    command in ("help", "--help", "-h") && return _usage(out)
    command in ("ls", "list") && return (_list_servers(out); 0)
    command == "start" && return _start_server(rest; out)
    command == "kill" && return _kill_server(rest; out)
    command == "interrupt" && return _interrupt_server(rest; out, err)
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
