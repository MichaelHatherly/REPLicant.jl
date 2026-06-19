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
Each request is length-prefixed: an ASCII decimal byte count, a newline, then that
many UTF-8 bytes of code. The server writes the result and closes the socket; the
client reads to EOF. A zero-length request is a health no-op that replies empty.
Requests are capped at 16 MB.

# Example
```julia
server = REPLicant.Server()
server = REPLicant.Server(; max_connections = 50, read_timeout_seconds = 60.0)
close(server)
```

The server runs in its own task. Several can run per project; label one with
[`label!`](@ref) to select it by name. The registry entry is removed on shutdown.
At capacity, clients get "ERROR: Server at capacity, please retry".
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

# Request struct to hold client connection information
struct ClientRequest
    socket::Sockets.TCPSocket
    id::Int
end

"""
    close(server::Server)

Shut down the server: interrupt its task, close active connections, and remove its
registry entry.
"""
Base.close(server::Server) = schedule(server.task, InterruptException(); error = true)

function _server(srv::Server)
    channel = srv.channel
    mod = srv.mod
    max_connections = srv.max_connections
    read_timeout_seconds = srv.read_timeout_seconds
    verbose = srv.verbose

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
    verbose && @info "REPLicant listening" port_number project entry_path

    function shutdown()
        close(server)
        # Forget this process's server so a later `label!` can't rewrite a
        # removed entry.
        CURRENT_SERVER[] === srv && (CURRENT_SERVER[] = nothing)
        # Always remove the registry entry to keep the registry clean.
        return if isfile(entry_path)
            rm(entry_path; force = true)
            verbose && @info "Removed registry entry" entry_path
        end
    end

    # Ensure cleanup happens even if the Julia process is terminated.
    atexit() do
        try
            shutdown()
        catch error
            # Use @debug to avoid noise during forced shutdowns
            @debug "Error during shutdown" error
        end
    end

    put!(channel, port_number)

    # Queue accepted requests for the worker. Sized to `max_connections` so the
    # accept loop never blocks on `put!` before the capacity check can reject.
    request_queue = Channel{ClientRequest}(max_connections)

    # Track active connections to enforce limits
    active_connections = Threads.Atomic{Int}(0)

    # Start the worker task that processes requests sequentially
    worker = errormonitor(
        Threads.@spawn begin
            try
                for request in request_queue
                    try
                        _revise(
                            _handle_client,
                            request.socket,
                            request.id,
                            mod,
                            read_timeout_seconds,
                            verbose,
                        )
                    finally
                        # Always decrement counter when done with a connection
                        Threads.atomic_sub!(active_connections, 1)
                    end
                end
            catch error
                @error "Error in worker task" error
            end
        end
    )

    return try
        # Simple incrementing ID for request tracking in logs
        id = 0
        while true
            sock = Sockets.accept(server)
            id += 1

            # Check if at capacity
            if active_connections[] >= max_connections
                verbose && @warn "Connection rejected - server at capacity" id current =
                    active_connections[] max = max_connections
                # Reject off the accept loop so draining the request never blocks
                # accepting other connections.
                @async _reject_at_capacity(sock, id, read_timeout_seconds)
            else
                # Accept connection and increment counter
                Threads.atomic_add!(active_connections, 1)
                verbose &&
                    @info "Client connected" id peer = Sockets.getpeername(sock) active =
                    active_connections[]
                request = ClientRequest(sock, id)
                put!(request_queue, request)
            end
        end
    catch error
        # A closed listener (`close`/atexit) surfaces as IOError from `accept`;
        # an explicit shutdown surfaces as InterruptException. Both are normal.
        if isa(error, InterruptException) || isa(error, Base.IOError)
            verbose && @info "Server shutting down"
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
        shutdown()
    end
end
