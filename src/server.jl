#
# Socket server.
#

"""
    Server(; max_connections = 100, read_timeout_seconds = 30.0, save = false, verbose = false)

Start a persistent Julia REPL server on a TCP socket. It picks a free port from
8000, registers itself in the registry (see [`install_channel`](@ref)), and
evaluates code from clients until closed.

# Arguments
- `max_connections::Int = 100`: concurrent connections before new ones are rejected.
- `read_timeout_seconds::Float64 = 30.0`: per-request read timeout in seconds.
- `save::Bool = false`: record the handle so [`server`](@ref) returns it. Use it
  from a session (e.g. `startup.jl`) that starts a server without keeping the
  return value.
- `verbose::Bool = false`: log lifecycle and per-connection events. Off by default
  so interactive sessions stay quiet; errors always log.

# Protocol
Each message is a frame: a 10-byte header (`"REPL"` magic, a version byte, a type
byte, then a big-endian `UInt32` body length) followed by the body. Requests are
`eval` (body is code) or `ping`; responses are `ok`/`err` (body is the result or
error text) or `pong` (body is the worker's busy-since timestamp, empty when
idle). Every frame is validated for magic, version, type, and a 16 MB length cap
before its body is trusted.

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
    mod::Union{Module, Nothing}
    max_connections::Int
    read_timeout_seconds::Float64
    save::Bool
    verbose::Bool
    # Runtime details, filled by `_server` once it binds a port, so a handle can
    # be introspected without reading the registry. `name` is set by `label!`.
    port::Union{Int, Nothing}
    project::Union{String, Nothing}
    started::Union{Dates.DateTime, Nothing}
    name::String
    # When the worker is mid-evaluation, the time it started; `nothing` when idle.
    # Written only by the single worker task, read by ping responders for `ls`.
    busy_since::Union{Dates.DateTime, Nothing}

    function Server(
            mod = nothing;
            max_connections::Int = 100,
            read_timeout_seconds::Float64 = READ_TIMEOUT_SECONDS,
            save::Bool = false,
            verbose::Bool = false,
        )
        srv = new()
        srv.channel = Channel{Int}(1)
        srv.mod = mod
        srv.max_connections = max_connections
        srv.read_timeout_seconds = read_timeout_seconds
        srv.save = save
        srv.verbose = verbose
        srv.port = nothing
        srv.project = nothing
        srv.started = nothing
        srv.name = ""
        srv.busy_since = nothing
        srv.task = errormonitor(@async _server(srv))
        # Tie the channel's lifetime to the task so a startup failure closes the
        # channel and surfaces the error to `take!` instead of blocking forever.
        bind(srv.channel, srv.task)
        # Record this process's server so `label!` finds it without a handle and
        # `server()` can hand it back (gated on `save`).
        CURRENT_SERVER[] = srv
        return srv
    end
end

# The server running in this process, recorded at construction. `nothing` when
# none runs here. `label!` reads it; `server()` returns it only when `save`.
const CURRENT_SERVER = Ref{Union{Server, Nothing}}(nothing)

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
# on, its id, and the code to run. Pings never become a `ClientRequest`; they are
# answered in the dispatcher.
struct ClientRequest
    socket::Sockets.TCPSocket
    id::Int
    code::String
end

"""
    close(server::Server)

Shut down the server: interrupt its task, close active connections, and remove its
registry entry.
"""
Base.close(server::Server) = schedule(server.task, InterruptException(); error = true)

function _server(srv::Server)
    server, port_number, entry_path = _listen_and_register!(srv)
    # Route output per eval so a remote eval's output is captured while the
    # interactive REPL's still reaches the terminal.
    _install_routing!()
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

    # Let the OS pick an available port starting from 8000. This avoids
    # conflicts and doesn't require users to manage port allocation.
    port_number, server = Sockets.listenany(8000)
    port_number = Int(port_number)

    started = Dates.now()
    entry_path = _write_registry_entry(port_number, project; started)
    # Publish the runtime details on the handle for introspection.
    srv.port = port_number
    srv.project = project
    srv.started = started
    srv.verbose && @info "REPLicant listening" port_number project entry_path

    # Ensure cleanup happens even if the Julia process is terminated.
    atexit() do
        try
            _shutdown_server(server, srv, entry_path)
        catch error
            # Use @debug to avoid noise during forced shutdowns
            @debug "Error during shutdown" error
        end
    end

    return server, port_number, entry_path
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
        # Signal worker to stop by closing the queue
        close(request_queue)

        # Wait for worker to finish processing remaining requests
        try
            wait(worker)
        catch error
            @debug "Worker task error during shutdown" error
        end

        # Ensure cleanup runs even if the server loop fails
        _shutdown_server(server, srv, entry_path)
    end
end

# Close the listener, drop this process's handle, and remove the registry entry.
function _shutdown_server(listener, srv, entry_path)
    close(listener)
    _uninstall_routing!()
    # Forget this process's server so a later `label!` can't rewrite a
    # removed entry.
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
                    srv.busy_since = Dates.now()
                    try
                        _revise(
                            _handle_eval,
                            request.socket,
                            request.id,
                            request.code,
                            srv.mod,
                            srv.verbose,
                        )
                    finally
                        srv.busy_since = nothing
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
        @async _reject_at_capacity(sock, id, srv.read_timeout_seconds)
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

# Per-connection dispatcher. Reads one frame, answers a ping immediately so
# liveness never queues behind an evaluation, and hands an eval to the worker.
# Pings, framing errors, and bare disconnects release the connection here; the
# worker releases an eval connection when it finishes evaluating.
function _dispatch(
        sock::Sockets.TCPSocket, id::Int, request_queue::Channel{ClientRequest},
        active_connections::Threads.Atomic{Int}, srv::Server,
    )
    enqueued = false
    try
        frame = _read_frame(sock, REQUEST_TYPES; timeout_seconds = srv.read_timeout_seconds)
        if isnothing(frame)
            return  # bare disconnect, nothing to reply to
        elseif frame.type == REQUEST_PING
            _write_frame(sock, RESPONSE_PONG, _busy_marker(srv))
            srv.verbose && @info "Answered ping" id
        else
            put!(request_queue, ClientRequest(sock, id, frame.body))
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
    return
end
