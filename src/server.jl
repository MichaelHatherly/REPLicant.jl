#
# Socket server implementation
#

# Constants for protocol limits
const READ_TIMEOUT_SECONDS = 30.0
const MAX_LINE_LENGTH = 1024 * 1024  # 1MB

"""
    Server(; max_connections::Int = 100, read_timeout_seconds::Float64 = 30.0)

Create a persistent Julia REPL server that listens for code execution requests via TCP sockets.

The server automatically:
- Finds an available port (starting from 8000)
- Creates a `REPLICANT_PORT` file containing the port number
- Accepts connections and evaluates Julia code
- Returns results or error messages to clients
- Limits concurrent connections to prevent resource exhaustion
- Enforces timeouts on client requests

# Arguments
- `max_connections::Int = 100`: Maximum number of concurrent connections allowed
- `read_timeout_seconds::Float64 = 30.0`: Timeout for reading client requests (in seconds)
- `commands::Dict`: provides a way to register custom commands.

# Commands
Commands are special directives that can be sent by clients to perform specific actions
on the server. Use the syntax `#command-name arguments...` to invoke a command named
`command-name` with the provided `arguments`. The server supports a set of built-in commands:

- `#include-file <path>`: Includes a Julia file in the active module context
- `#test-item <item>`: Runs a specific test item by name
- `#test-tags <tags>...`: Runs tests filtered by tags

The custom commands can be registered in the `commands` dictionary when creating the server. The registered functions take three arguments:

- `code::AbstractString`: The command arguments as a string
- `id::Integer`: The request ID for logging
- `mod::Module`: The active module context where the command is executed

The function must return a thunk (a zero-argument function) that performs the
command action when called. Any values returned from the invoked thunk are
captured and returned to the client. Any printing to stdout will be captured
and sent back as part of the response.

# Protocol
- Each request must be a single line of Julia code terminated by a newline (`\\n`)
- Maximum line length: 1MB
- The server responds with the result followed by a newline
- Connection closes after each request

# Example
```julia
server = REPLicant.Server()  # Default settings
# or
server = REPLicant.Server(; max_connections = 50, read_timeout_seconds = 60.0)

# To stop the server:
close(server)
```

# Notes
- The server runs asynchronously in a separate task
- Only one server instance should run per project directory
- The `REPLICANT_PORT` file is automatically cleaned up on shutdown
- When at capacity, new connections receive "ERROR: Server at capacity, please retry"
- Requests without newlines will timeout with "ERROR: Read timeout"
"""
struct Server
    task::Task
    channel::Channel{Int}
    mod::Union{Module,Nothing}
    max_connections::Int
    read_timeout_seconds::Float64

    function Server(
        mod = nothing;
        max_connections::Int = 100,
        read_timeout_seconds::Float64 = READ_TIMEOUT_SECONDS,
        commands::Dict = Dict{String,Function}(),
    )
        channel = Channel{Int}(1)
        task = @async _server(
            $channel,
            $mod,
            $max_connections,
            $read_timeout_seconds,
            $commands,
        )
        return new(task, channel, nothing, max_connections, read_timeout_seconds)
    end
end

# Request struct to hold client connection information
struct ClientRequest
    socket::Sockets.TCPSocket
    id::Int
end

"""
    close(server::Server)

Gracefully shut down the REPLicant server and clean up resources.

This will:
- Interrupt the server task
- Close all active connections
- Remove the `REPLICANT_PORT` file
"""
Base.close(server::Server) = schedule(server.task, InterruptException(); error = true)

function _server(
    channel::Channel{Int},
    mod::Union{Module,Nothing},
    max_connections::Int,
    read_timeout_seconds::Float64,
    commands::Dict,
)
    # We require a justfile to determine the project root directory. This ensures
    # the server runs in the context of a specific project and provides a clear
    # contract for client tools (they need the justfile recipes).
    justfile = _find_just_file()
    isnothing(justfile) && error("Could not find justfile in project.")
    project_dir = dirname(justfile)

    # The port file serves as both a discovery mechanism for clients and a
    # lock to prevent multiple servers in the same project.
    port_file = joinpath(project_dir, "REPLICANT_PORT")
    isfile(port_file) && error("REPLICANT_PORT file already exists at $port_file.")

    # Let the OS pick an available port starting from 8000. This avoids
    # conflicts and doesn't require users to manage port allocation.
    port_number, server = Sockets.listenany(8000)
    port_number = Int(port_number)

    # Write the port atomically to prevent TOCTOU race conditions and partial reads.
    # We write to a temporary file first, then rename it. Rename is atomic on POSIX systems.
    temp_file = port_file * ".tmp.$(getpid())"
    try
        open(temp_file, "w") do f
            write(f, string(port_number))
        end
        # Atomic rename - will fail if destination exists, preventing races
        mv(temp_file, port_file; force = false)
    catch error
        # Clean up temp file if something went wrong
        isfile(temp_file) && rm(temp_file; force = true)
        # If the port file was created by another process, that's the likely error
        if isfile(port_file)
            close(server)
            error(
                "Another REPLicant server started while initializing. REPLICANT_PORT file exists at $port_file.",
            )
        else
            rethrow(error)
        end
    end
    @info "REPLicant listening" port_number port_file

    function shutdown()
        close(server)
        # Always clean up the port file to prevent stale locks
        if isfile(port_file)
            rm(port_file)
            @info "Cleaned up REPLICANT_PORT file" port_file
        end
    end

    # Ensure cleanup happens even if the Julia process is terminated.
    # This prevents stale port files from blocking future servers.
    atexit() do
        try
            shutdown()
        catch error
            # Use @debug to avoid noise during forced shutdowns
            @debug "Error during shutdown" error
        end
    end

    put!(channel, port_number)

    # Create a queue for client requests with reasonable buffer size
    request_queue = Channel{ClientRequest}(32)

    # Track active connections to enforce limits
    active_connections = Threads.Atomic{Int}(0)

    # Start the worker task that processes requests sequentially
    worker = Threads.@spawn begin
        try
            for request in request_queue
                try
                    _revise(
                        _handle_client,
                        request.socket,
                        request.id,
                        mod,
                        read_timeout_seconds,
                        commands,
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

    try
        # Simple incrementing ID for request tracking in logs
        id = 0
        while true
            sock = Sockets.accept(server)
            id += 1

            # Check if at capacity
            if active_connections[] >= max_connections
                # Reject immediately
                try
                    write(sock, "ERROR: Server at capacity, please retry\n")
                    flush(sock)
                    @warn "Connection rejected - server at capacity" id current =
                        active_connections[] max = max_connections
                catch error
                    # Client may have disconnected
                    @debug "Failed to send capacity error to client" id error
                finally
                    close(sock)
                end
            else
                # Accept connection and increment counter
                Threads.atomic_add!(active_connections, 1)
                @info "Client connected" id peer = Sockets.getpeername(sock) active =
                    active_connections[]
                request = ClientRequest(sock, id)
                put!(request_queue, request)
            end
        end
    catch error
        if isa(error, InterruptException)
            @info "Server shutting down"
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

function _readline_with_timeout(
    sock;
    timeout_seconds = READ_TIMEOUT_SECONDS,
    max_length = MAX_LINE_LENGTH,
)
    # Create a task to read the line
    read_task = @async begin
        try
            line = readline(sock)
            # Check line length after reading
            if length(line) > max_length
                ErrorException("Line too long: exceeds maximum of $(max_length) bytes")
            else
                line
            end
        catch e
            e
        end
    end

    # Wait for the task with timeout
    start_time = time()
    while !istaskdone(read_task)
        if time() - start_time > timeout_seconds
            # Timeout occurred - don't close socket yet, just return timeout error
            # The error handler in _handle_client will send the error message
            throw(
                ErrorException(
                    "Read timeout: no data received within $(timeout_seconds) seconds",
                ),
            )
        end
        sleep(0.001)
    end

    # Get the result
    result = fetch(read_task)
    if result isa Exception
        throw(result)
    else
        return result
    end
end

function _handle_client(sock, id, mod, read_timeout_seconds, commands)
    try
        # Protocol: single line of Julia code terminated by newline.
        # We strip whitespace to handle various client implementations.
        code = strip(_readline_with_timeout(sock; timeout_seconds = read_timeout_seconds))

        @info "Received code" id code = Text(code)

        # Execute the code and capture all outputs
        result = _eval_code(code, id, mod, commands)

        # Protocol: send result followed by newline for easy parsing
        write(sock, result * "\n")
        flush(sock)

        @info "Sent result" id result = Text(result)
    catch error
        error_msg = "ERROR: $(error)"
        @error "Error handling client" id error
        try
            # Attempt to inform the client about the error
            write(sock, error_msg * "\n")
            flush(sock)
        catch error
            # Client disconnected before we could send the error.
            # This is common when clients timeout or are killed.
            @error "Failed to send error message to client" id error
        end
    finally
        # Always close the socket to free resources
        close(sock)
        @info "Client disconnected" id
    end
end
