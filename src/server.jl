#
# Socket server.
#

# Named sessions (`--module`), each a standalone module reused across calls. The
# lock is collocated with the modules it guards: the worker reads on eval, the
# dispatcher rewrites an entry on reset, so every access takes the lock.
struct SessionStore
    lock::ReentrantLock
    modules::Dict{String, Module}
end
SessionStore() = SessionStore(ReentrantLock(), Dict{String, Module}())

"""
    Server([mod]; max_connections = 100, read_timeout_seconds = 30.0, save = false, verbose = false)

Start a persistent Julia REPL server on a TCP socket. It binds a free port the
OS assigns, registers itself in the registry (see [`install_channel`](@ref)), and
evaluates code from clients until closed.

# Arguments
- `mod`: the default eval target. A `Module` evaluates every default-session
  request there; a zero-argument callable returning a module is resolved per
  request, so the host can swap the target between calls. Omitted, requests
  evaluate into the active module.
- `max_connections::Int = 100`: concurrent connections before new ones are rejected.
- `read_timeout_seconds::Float64 = 30.0`: per-request read timeout in seconds.
- `save::Bool = false`: record the handle so [`server`](@ref) returns it. Use it
  from a session (e.g. `startup.jl`) that starts a server without keeping the
  return value. Unsaved servers started later, as a test suite starts them, leave
  it as the server `label!` and the footer act on.
- `verbose::Bool = false`: log lifecycle and per-connection events. Off by default
  so interactive sessions stay quiet; errors always log.

# Protocol
Each message is a frame: a 10-byte header (`"REPL"` magic, a version byte, a type
byte, then a big-endian `UInt32` body length) followed by the body. Every request
body opens with the 64-character token from the server's registry entry, and the
server rejects a request without it: any local user can reach the port, while
only the owner can read the owner-only registry. Requests are `eval` (body carries the caller's working directory, the target session module, and
the code), `ping`, `interrupt`, `reset` (body is a session module name), `log`, or
`restart`; responses are `ok`/`err` (body is the result or error text) or `pong`
(body is the worker's busy-since timestamp, empty when idle). An `interrupt`
schedules an `InterruptException` onto the running eval (a no-op when idle), a
`reset` swaps a named session for a fresh module, and a `restart` re-execs the
process on its launch argv, keeping its pid and terminal (macOS and Linux only). All
are answered off the worker queue, like `ping`, so they reach a busy server. Every frame is validated for magic, version,
type, and a 16 MB length cap before its body is trusted.

# Example
```julia
server = REPLicant.Server()
server = REPLicant.Server(; max_connections = 50, read_timeout_seconds = 60.0)
close(server)
```

The server runs in its own task. Several can run per project; label one with
[`label!`](@ref) to select it by name. The registry entry is removed on shutdown.
At capacity, clients get an `err` frame carrying "Server at capacity, please retry".
"""
mutable struct Server
    task::Task
    channel::Channel{Int}
    # Resolves the default eval target on each request. A fixed module and the
    # active-module fallback are normalized to zero-argument callables at
    # construction, so a host can equally hand in its own callable to swap the
    # target between calls.
    mod::Base.Callable
    max_connections::Int
    read_timeout_seconds::Float64
    save::Bool
    verbose::Bool
    # Every request must carry this; clients read it from the registry entry.
    token::String
    # Runtime details, filled by `_server` once it binds a port, so a handle can
    # be introspected without reading the registry. `name` is set by `label!`.
    port::Union{Int, Nothing}
    project::Union{String, Nothing}
    started::Union{Dates.DateTime, Nothing}
    name::String
    # When the worker is mid-evaluation, the time it started; `nothing` when idle.
    # Written only by the single worker task, read by ping responders for `ls`.
    busy_since::Union{Dates.DateTime, Nothing}
    # The code of the latest evaluation, current only while `busy_since` is set.
    busy_code::String
    # Notified to request an interrupt of the eval in flight; `nothing` when idle.
    # The dispatcher notifies it off the worker queue; a watcher pinned to the
    # eval's thread answers, scheduling the `InterruptException` only while the eval
    # is parked. Same-thread delivery is the only safe way to throw into a
    # cooperatively-running task. Written by the worker, read by the dispatcher.
    interrupt_signal::Union{Base.Event, Nothing}
    # Named sessions (`--module`), with the lock that serializes worker eval against
    # dispatcher reset.
    sessions::SessionStore

    function Server(
            mod = nothing;
            max_connections::Int = 100,
            read_timeout_seconds::Float64 = READ_TIMEOUT_SECONDS,
            save::Bool = false,
            verbose::Bool = false,
        )
        srv = new()
        srv.channel = Channel{Int}(1)
        srv.mod = _default_target(mod)
        srv.max_connections = max_connections
        srv.read_timeout_seconds = read_timeout_seconds
        srv.save = save
        srv.verbose = verbose
        srv.token = _new_token()
        srv.port = nothing
        srv.project = nothing
        srv.started = nothing
        srv.name = ""
        srv.busy_since = nothing
        srv.busy_code = ""
        srv.interrupt_signal = nothing
        srv.sessions = SessionStore()
        srv.task = errormonitor(@async _server(srv))
        # Tie the channel's lifetime to the task so a startup failure closes the
        # channel and surfaces the error to `take!` instead of blocking forever.
        bind(srv.channel, srv.task)
        _record_server!(srv)
        return srv
    end
end

# Normalize the constructor's default-target argument to a zero-argument callable
# resolved per request. A `Module` is fixed; `nothing` defers to the active module; a
# host's own callable can swap the target between calls (e.g. a notebook module
# replaced on re-init). Resolved by `_request_module` when a default-session request
# is accepted.
_default_target(mod::Module) = () -> mod
_default_target(::Nothing) = Base.active_module
_default_target(f::Base.Callable) = f

# The server running in this process, recorded at construction. `nothing` when
# none runs here. `label!` and the footer read it; `server()` returns it only when
# `save`.
const CURRENT_SERVER = Ref{Union{Server, Nothing}}(nothing)

# The latest server takes the slot, except that an unsaved one, as a test suite
# starts, never displaces a running saved server, the session's own.
function _record_server!(srv::Server)
    held = CURRENT_SERVER[]
    protected = !isnothing(held) && held.save && !istaskdone(held.task)
    (srv.save || !protected) && (CURRENT_SERVER[] = srv)
    return nothing
end

# The running server when started with `save = true`, else `nothing`. For
# interactive use: `close(REPLicant.server())`.
function server()
    handle = CURRENT_SERVER[]
    handle === nothing && return nothing
    (handle.save && !istaskdone(handle.task)) || return nothing
    return handle
end

function Base.show(io::IO, ::MIME"text/plain", srv::Server)
    print(io, "REPLicant.Server")
    if istaskdone(srv.task)
        print(io, " (stopped)")
        return
    end
    if srv.port === nothing
        print(io, " (starting)")
    else
        print(io, " (running)")
        print(io, "\n  port:            ", srv.port)
        print(io, "\n  project:         ", srv.project)
        isempty(srv.name) || print(io, "\n  name:            ", srv.name)
        print(io, "\n  started:         ", srv.started)
    end
    print(io, "\n  max_connections: ", srv.max_connections)
    print(io, "\n  read_timeout:    ", srv.read_timeout_seconds, "s")
    return
end

# An evaluation handed from the dispatcher to the worker: the connection to reply
# on, its id, the code to run, the caller's working directory (the eval runs there;
# empty keeps the server's cwd), and the module to evaluate into. The module is
# resolved in the dispatcher when the request is accepted, so a `reset` that arrives
# afterward cannot swap an already-queued eval's session out from under it. Pings,
# interrupts, and resets never become a `ClientRequest`; they are answered in the
# dispatcher.
struct ClientRequest
    socket::Sockets.TCPSocket
    id::Int
    code::String
    cwd::String
    mod::Module
end

"""
    close(server::Server)

Shut down the server: interrupt its task, close active connections, and remove its
registry entry. Closing a stopped server does nothing.
"""
function Base.close(server::Server)
    istaskdone(server.task) || schedule(server.task, InterruptException(); error = true)
    return nothing
end

function _server(srv::Server)
    server, port_number, entry_path = _listen_and_register!(srv)
    # Capture human-typed activity into the log (a no-op without an interactive REPL).
    _install_activity_capture()
    # Signal readiness now that the registry entry exists.
    put!(srv.channel, port_number)
    return _serve(server, srv, entry_path)
end

# Bind a listener, register it, and publish its runtime details on the handle.
# Returns the listener, its port, and its registry entry path.
function _listen_and_register!(srv::Server)
    # Root the server at the enclosing project. Clients select by this path.
    project = _project_root()

    # Drop stale entries for this project. Several live servers per project are
    # allowed; clients disambiguate by label (see `label!`) or port.
    _prune_dead_entries(project)

    # Let the OS assign an ephemeral port. Low ports like 8000 collide with dev
    # servers, and the HTTP health checks aimed at them would land here instead.
    port_number, server = Sockets.listenany(0)
    port_number = Int(port_number)

    started = Dates.now()
    entry_path = _write_registry_entry(port_number, project; srv.token, started)
    # Publish the runtime details on the handle for introspection.
    srv.port = port_number
    srv.project = project
    srv.started = started
    srv.verbose && @info "REPLicant listening" port_number project entry_path
    # A saved server is the one clients will call, so ready their image now.
    srv.save && _build_client_image()

    Base.@lock SERVERS_LOCK begin
        SERVERS[srv] = (server, entry_path)
        # Route output per eval so a remote eval's output is captured while the
        # interactive REPL's still reaches the terminal.
        _install_routing!()
        EXIT_HOOKED[] || (atexit(_exit_cleanup); EXIT_HOOKED[] = true)
    end

    return server, port_number, entry_path
end

# This process's servers, from listening until their worker finishes. The value is
# the listener and registry entry while registered, `nothing` after, so exit never
# unregisters a closed server's old port. Routing stays installed while any remain,
# since an eval still running when its server closes is capturing through it.
const SERVERS = IdDict{Server, Union{Tuple{Sockets.TCPServer, String}, Nothing}}()
const SERVERS_LOCK = ReentrantLock()
const EXIT_HOOKED = Ref(false)

# Leave the table once the worker has finished, uninstalling routing after the last
# server. Idempotent per server: shutdown runs from both the serve loop and `atexit`.
function _release_routing!(srv::Server)
    Base.@lock SERVERS_LOCK begin
        haskey(SERVERS, srv) || return nothing
        delete!(SERVERS, srv)
        isempty(SERVERS) && _uninstall_routing!()
    end
    return nothing
end

# Clean up after every registered server as the process exits. A restart keeps the
# listener open: closing it ends the server task, and a script blocked on that task
# would return and exit the process before the re-exec.
function _exit_cleanup()
    registered = Tuple{Server, Sockets.TCPServer, String}[]
    Base.@lock SERVERS_LOCK for (srv, registration) in SERVERS
        registration === nothing || push!(registered, (srv, registration[1], registration[2]))
    end
    for (srv, listener, entry_path) in registered
        try
            RESTARTING[] ? _unregister!(srv, entry_path) :
                _shutdown_server(listener, srv, entry_path)
        catch error
            # Use @debug to avoid noise during forced shutdowns
            @debug "Error during shutdown" error
        end
    end
    return nothing
end

# Run the accept loop with its worker, draining and shutting down on exit.
function _serve(server, srv::Server, entry_path)
    # Queue accepted requests for the worker. Sized to `max_connections` so the
    # accept loop never blocks on `put!` before the capacity check can reject.
    request_queue = Channel{ClientRequest}(srv.max_connections)

    # Track active connections to enforce limits
    active_connections = Threads.Atomic{Int}(0)

    # Start the worker task that processes requests sequentially
    worker = _spawn_worker(request_queue, active_connections, srv)

    return try
        _accept_loop(server, request_queue, active_connections, srv)
    catch error
        # A closed listener (`close`/atexit) surfaces as IOError from `accept`;
        # an explicit shutdown surfaces as InterruptException. Both are normal.
        if isa(error, InterruptException) || isa(error, Base.IOError)
            srv.verbose && @info "Server shutting down"
        else
            @error "Unexpected error in server loop" error
        end
    finally
        # Closing the queue stops the worker, which refuses what is still queued.
        close(request_queue)
        _interrupt_eval(srv)
        # Unregister before waiting, since an eval that never yields ignores the
        # interrupt and would keep the worker running.
        _close_and_unregister!(server, srv, entry_path)
        try
            wait(worker)
        catch error
            @debug "Worker task error during shutdown" error
        end
        _release_routing!(srv)
    end
end

const SHUTTING_DOWN = "Server shutting down"

# Hand a request to the worker. A queue closed by shutdown refuses it.
function _enqueue!(request_queue::Channel{ClientRequest}, request::ClientRequest)
    try
        put!(request_queue, request)
    catch error
        error isa InvalidStateException || rethrow()
        throw(RequestError(SHUTTING_DOWN))
    end
    return nothing
end

# Answer a request the closing server will not evaluate.
function _refuse_shutting_down(request::ClientRequest, active_connections::Threads.Atomic{Int})
    try
        _write_frame(request.socket, RESPONSE_ERR, SHUTTING_DOWN)
    catch error
        @debug "Failed to send shutdown error to client" id = request.id error
    finally
        close(request.socket)
        Threads.atomic_sub!(active_connections, 1)
    end
    return nothing
end

# Close the listener, drop this process's handle, and remove the registry entry, then
# give up this server's hold on output routing.
function _shutdown_server(listener, srv::Server, entry_path)
    _close_and_unregister!(listener, srv, entry_path)
    return _release_routing!(srv)
end

# Stop taking connections and leave the registry. Routing stays, since an eval still
# running when the server closes is capturing through it.
function _close_and_unregister!(listener, srv::Server, entry_path)
    Base.@lock SERVERS_LOCK haskey(SERVERS, srv) && (SERVERS[srv] = nothing)
    close(listener)
    return _unregister!(srv, entry_path)
end

# Drop this process's handle and remove the registry entry.
function _unregister!(srv, entry_path)
    # Forget this process's server so a later `label!` can't rewrite a removed entry.
    CURRENT_SERVER[] === srv && (CURRENT_SERVER[] = nothing)
    # Always remove the registry entry to keep the registry clean.
    return if isfile(entry_path)
        rm(entry_path; force = true)
        srv.verbose && @info "Removed registry entry" entry_path
    end
end

# Worker task: evaluate queued requests sequentially in the persistent module.
function _spawn_worker(request_queue, active_connections, srv::Server)
    return errormonitor(
        Threads.@spawn begin
            try
                for request in request_queue
                    if !isopen(request_queue)
                        _refuse_shutting_down(request, active_connections)
                        continue
                    end
                    # Run the eval in its own task so an interrupt request frees it
                    # without unwinding the worker loop. The worker stays sequential:
                    # it waits for each eval before taking the next, so only one eval
                    # task, and one output capture, exists at a time. The task is
                    # sticky (`@async`, not `Threads.@spawn`): the watcher below
                    # schedules the interrupt from this same thread, so the eval must
                    # stay pinned to it.
                    eval_task = @async _handle_eval(
                        request.socket,
                        request.id,
                        request.code,
                        request.mod,
                        srv.verbose,
                        request.cwd,
                    )
                    # Deliver an interrupt on the eval's own thread. Pinned there by
                    # `@async`, the watcher runs only when the eval has yielded, so
                    # `schedule` lands on a parked task, the only safe way to throw an
                    # exception into a cooperatively-running task. The dispatcher
                    # notifies `signal` off the worker queue; the `finally` notify
                    # releases the watcher when no interrupt arrives.
                    signal = Base.Event()
                    watcher = @async begin
                        wait(signal)
                        if !istaskdone(eval_task)
                            try
                                schedule(eval_task, InterruptException(); error = true)
                            catch  # dendro-ignore: empty_catch -- eval finished between the check and the schedule
                            end
                        end
                    end
                    srv.interrupt_signal = signal
                    # A close between the check above and publishing the signal
                    # found nothing to interrupt.
                    isopen(request_queue) || notify(signal)
                    _set_busy!(srv, Dates.now(), request.code)
                    try
                        wait(eval_task)
                    catch error
                        # `_handle_eval` reports eval and revision errors to the client
                        # itself, so a throw here is the eval task failing unexpectedly.
                        # Log it and keep the worker alive.
                        @error "Eval task failed" id = request.id error
                    finally
                        srv.interrupt_signal = nothing
                        _set_busy!(srv, nothing)
                        notify(signal)
                        wait(watcher)
                        # Always decrement counter when done with a connection
                        Threads.atomic_sub!(active_connections, 1)
                    end
                end
            catch error
                @error "Error in worker task" error
            end
        end
    )
end

# Accept connections forever, queuing each for the worker; reject at capacity.
function _accept_loop(server, request_queue, active_connections, srv::Server)
    # Simple incrementing ID for request tracking in logs
    id = 0
    while true
        # `listenany` hands back a `TCPServer`, so `accept` yields a `TCPSocket`;
        # assert it so the socket stays concretely typed through the accept loop.
        sock = Sockets.accept(server)::Sockets.TCPSocket
        id += 1
        _admit(sock, id, request_queue, active_connections, srv)
    end
    return
end

# Admit one accepted connection: reject at capacity, else count it and dispatch it
# off the accept loop. A function barrier so the spawned tasks capture stable
# arguments instead of the loop's reassigned `sock`/`id`, which would box.
function _admit(
        sock::Sockets.TCPSocket, id::Int, request_queue::Channel{ClientRequest},
        active_connections::Threads.Atomic{Int}, srv::Server,
    )
    if active_connections[] >= srv.max_connections
        srv.verbose && @warn "Connection rejected - server at capacity" id current =
            active_connections[] max = srv.max_connections
        # Reject off the accept loop so draining the request never blocks accepting.
        @async _reject_at_capacity(sock, id, srv.token, srv.read_timeout_seconds)
    else
        Threads.atomic_add!(active_connections, 1)
        srv.verbose &&
            @info "Client connected" id peer = Sockets.getpeername(sock) active =
            active_connections[]
        # Dispatch off the accept loop so reading the frame and answering a ping
        # never blocks accepting other connections.
        @async _dispatch(sock, id, request_queue, active_connections, srv)
    end
    return
end

# The pong body: the worker's busy-since timestamp, or empty when idle. Clients
# render it in `ls` to tell a wedged server from an idle one.
_busy_marker(srv::Server) = isnothing(srv.busy_since) ? "" : string(srv.busy_since)

# The terminal title and the footer's status row read `busy_since`, so each change
# to it updates the title and asks for a repaint; an eval that finishes quickly
# would otherwise never be seen to have started. The code is written first, so a
# reader that sees the time also sees its code.
function _set_busy!(
        srv::Server, since::Union{Dates.DateTime, Nothing}, code::AbstractString = srv.busy_code,
    )
    srv.busy_code = code
    srv.busy_since = since
    # Request the repaint before the title write, which can yield.
    Footers.update!()
    __notify_busy(nothing)
    return nothing
end

# True while this process's server, the one the title and footer report, is
# mid-evaluation. A test server evaluating in the same process leaves it false.
function _is_busy()
    srv = CURRENT_SERVER[]
    return !isnothing(srv) && !isnothing(srv.busy_since)
end

# Two-layer dispatch, mirroring `_revise`/`_help`. The REPL extension overrides
# `__notify_busy(::Nothing)` to set the terminal title; `_set_busy!` calls it on
# both edges of an evaluation. Without REPL the `::Any` fallback does nothing.
__notify_busy(::Any) = nothing

# Request an interrupt of the running eval, freeing a wedged worker without killing
# the process. Returns whether an eval was running to interrupt. Called from the
# dispatcher, off the worker queue, so it reaches a server whose worker is wedged.
# Notifying the signal wakes the watcher on the eval's thread, which schedules the
# `InterruptException`. Delivery is cooperative: a tight non-yielding loop never
# hits a safepoint, so `kill` remains the only recourse there.
function _interrupt_eval(srv::Server)
    signal = srv.interrupt_signal
    isnothing(signal) && return false
    notify(signal)
    return true
end

# Per-connection dispatcher. Reads one frame, answers a ping immediately so
# liveness never queues behind an evaluation, and hands an eval to the worker.
# Pings, framing errors, and bare disconnects release the connection here; the
# worker releases an eval connection when it finishes evaluating.
function _dispatch(
        sock::Sockets.TCPSocket, id::Int, request_queue::Channel{ClientRequest},
        active_connections::Threads.Atomic{Int}, srv::Server,
    )
    enqueued = false
    restart = false
    shutdown = false
    try
        frame = _read_request(sock, srv.token, srv.read_timeout_seconds)
        if isnothing(frame)
            return  # bare disconnect, nothing to reply to
        elseif frame.type == REQUEST_PING
            _write_frame(sock, RESPONSE_PONG, _busy_marker(srv))
            srv.verbose && @info "Answered ping" id
        elseif frame.type == REQUEST_INTERRUPT
            delivered = _interrupt_eval(srv)
            _write_frame(sock, RESPONSE_OK, delivered ? "interrupted" : "no evaluation running")
            srv.verbose && @info "Answered interrupt" id delivered
        elseif frame.type == REQUEST_RESET
            # Reset is answered off the worker queue, like ping and interrupt. It
            # rebinds the named session module, so a later eval into that name gets
            # a clean module; an eval already in flight finishes in the old one.
            _write_frame(sock, RESPONSE_OK, _reset_session(srv, frame.body))
            srv.verbose && @info "Answered reset" id name = frame.body
        elseif frame.type == REQUEST_LOG
            # Log is answered off the worker queue too, so the agent can read recent
            # activity while a long eval is still running.
            _write_frame(sock, RESPONSE_OK, _render_activity_log(frame.body))
            srv.verbose && @info "Answered log" id
        elseif frame.type == REQUEST_RESTART
            # Answered off the worker queue, so a server wedged on an eval restarts too.
            # The re-exec waits until the reply is sent and the socket closed below.
            _check_restartable()
            _write_frame(sock, RESPONSE_OK, "restarting")
            restart = true
        elseif frame.type == REQUEST_SHUTDOWN
            # Exits from this task once the socket is closed below. A SIGTERM runs the
            # exit hooks wherever the main thread was, and inside a libuv callback
            # they hang.
            _write_frame(sock, RESPONSE_OK, "shutting down")
            shutdown = true
        else
            decoded = _decode_eval_body(frame.body)
            # Resolve the target module now, while accepting the request, so a later
            # reset cannot change which module this eval runs in.
            mod = _request_module(srv, decoded.mod)
            isempty(decoded.cwd) || isdir(decoded.cwd) ||
                throw(RequestError("no such directory: $(decoded.cwd)"))
            _enqueue!(request_queue, ClientRequest(sock, id, decoded.code, decoded.cwd, mod))
            enqueued = true
        end
    catch error
        _reply_error(sock, id, error)
    finally
        # The worker owns the connection once enqueued; otherwise release it here.
        if !enqueued
            close(sock)
            Threads.atomic_sub!(active_connections, 1)
            srv.verbose && @info "Client disconnected" id
        end
    end
    restart && _reexec()
    shutdown && exit()
    return
end
