"""
    REPLicant

A persistent Julia REPL server that enables fast code execution for CLI-based tools and coding agents.

# Exports
- `Server`: A socket server that evaluates Julia code sent by clients

# Example
```julia
using REPLicant
server = REPLicant.Server()  # Start the server
# ... use the server ...
close(server)  # Clean shutdown
```
"""
module REPLicant

#
# Imports.
#

import IOCapture
import Sockets

#
# Socket server.
#

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

# Constants for protocol limits
const READ_TIMEOUT_SECONDS = 30.0
const MAX_LINE_LENGTH = 1024 * 1024  # 1MB

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

#
# Code evaluation.
#

function _include_file_command(code::AbstractString, id::Integer, mod::Module)
    root = dirname(_find_just_file())
    path = joinpath(root, code)
    if isfile(path)
        # Include the file in the active module context
        @info "Including file" id path = Text(path)
        return () -> Base.include(mod, path)
    else
        error("File not found: $path")
    end
end

function _test_item_command(item::AbstractString, id::Integer, mod::Module)
    _try_load_test_item_runner(mod)
    code = "@run_package_tests filter=ti->ti.name == $(repr(item))"
    @info "Running test item" id code
    return () -> include_string(mod, code, "REPL[$id]")
end

function _test_tags_command(tags::AbstractString, id::Integer, mod::Module)
    _try_load_test_item_runner(mod)
    tags = Symbol.(split(strip(tags), ' '))
    code = "@run_package_tests filter=ti->issubset($(repr(tags)), ti.tags)"
    @info "Running tests with tags filter" id code
    return () -> include_string(mod, code, "REPL[$id]")
end

function _try_load_test_item_runner(mod::Module)
    # This command is used to run specific test items.
    # It expects a TestItemRunner to be available in the module context.
    if !isdefined(mod, :TestItemRunner)
        try
            Core.eval(mod, :(using TestItemRunner))
        catch error
            error("TestItemRunner not found in module context: $error")
        end
    end
end

function _eval_code(
    code::AbstractString,
    id::Integer,
    mod::Union{Module,Nothing},
    commands::Dict = Dict{String,Function}(),
)
    # Use the active module to maintain state between evaluations.
    # This allows users to define variables and use them in subsequent calls.
    mod = @something(mod, Base.active_module())
    try
        m = match(r"^#([a-z][a-z\-]+)\s+", code)
        thunk = if isnothing(m)
            () -> include_string(mod, code, "REPL[$id]")
        else
            command_string = m[1]
            default_commands = Dict(
                # Commands:
                "include-file" => _include_file_command,
                "test-item" => _test_item_command,
                "test-tags" => _test_tags_command,
            )
            available_commands = merge(default_commands, commands)
            command = get(available_commands, command_string, nothing)
            if isnothing(command)
                error("Unknown command: $command_string")
            else
                # Call the command with the rest of the code
                command(lstrip(code[(length(m.match)+1):end]), id, mod)
            end
        end
        # IOCapture handles both stdout and the return value, giving us
        # REPL-like behavior. We rethrow InterruptException to allow
        # graceful interruption of long-running code.
        result = IOCapture.capture(thunk; rethrow = InterruptException)

        buffer = IOBuffer()
        # Stdout output comes first, just like in the REPL
        if !isempty(result.output)
            println(buffer, rstrip(result.output))
        end

        if result.error
            _error_message(buffer, result, id)
        else
            _echo_object(result.value) && _show_object(buffer, result, mod)
        end

        return String(take!(buffer))
    catch error
        # This catches errors that occur outside of IOCapture,
        # such as syntax errors during parsing.
        @error "Error evaluating code" id code error
        return "ERROR: $(error)"
    end
end

_echo_object(object) = true

function _show_object(buffer, result, mod)
    # Mimic REPL display settings: limit output size, no color codes
    # (since we're sending over a socket), and use the correct module
    # context for printing types.
    ctx = IOContext(buffer, :limit => true, :color => false, :module => mod)
    show(ctx, "text/plain", result.value)
end

function _error_message(buffer, result, id)
    # Clean up the backtrace to match REPL behavior. We truncate at the
    # first "top-level scope" frame since everything above that is
    # internal REPLicant machinery that users don't need to see.
    bt = Base.scrub_repl_backtrace(result.backtrace::Vector)
    top_level = findfirst(x -> x.func === Symbol("top-level scope"), bt)
    bt = bt[1:something(top_level, length(bt))]

    print(buffer, "ERROR: ")
    showerror(buffer, result.value.error, bt)
end

#
# Revise integration.
#

# Two-layer dispatch pattern for optional dependency support.
# When Revise isn't loaded, __revise falls back to direct execution.
# When the extension loads, it overrides __revise to check for pending
# revisions before invoking the function.
_revise(f, args...; kws...) = __revise(nothing, f, args...; kws...)
__revise(::Any, f, args...; kws...) = f(args...; kws...)

#
# File system utilities.
#

function _find_just_file(dir::AbstractString = pwd())
    # Walk up the directory tree looking for a justfile.
    # Stop at git repository boundaries to avoid escaping the project.
    visited_dirs = Set{String}()

    choices = ("justfile", "Justfile", "JUSTFILE", ".justfile", ".Justfile", ".JUSTFILE")

    while true
        # Prevent infinite loops from symlinks or filesystem issues
        if dir in visited_dirs
            @warn "Circular directory structure detected while searching for justfile" dir
            return nothing
        end
        push!(visited_dirs, dir)

        for each in choices
            just_file = joinpath(dir, each)
            try
                if isfile(just_file)
                    return just_file
                end
            catch error
                # Log permission errors but continue searching upward.
                # If we can't read a directory, we likely can't read its parent either,
                # so we'll reach the root and exit gracefully.
                @debug "Error checking for justfile" dir error
            end
        end

        # Use .git as a boundary - don't search beyond the repository root
        try
            git_dir = joinpath(dir, ".git")
            if isdir(git_dir)
                return nothing
            end
        catch error
            # Permission error checking for .git, continue searching
            @debug "Error checking for .git directory" dir error
        end

        parent_dir = dirname(dir)
        if parent_dir == dir  # Reached filesystem root
            return nothing
        end
        dir = parent_dir
    end
end

#
# Justfile setup.
#

const JUSTFILE_RECIPES = """
# Execute Julia code via REPLicant
julia code:
    printf '%s' "{{code}}" | nc localhost \$(cat REPLICANT_PORT)

# Documentation lookup
docs binding:
    just julia "@doc {{binding}}"

# Run all tests
test-all:
    just julia "@run_package_tests"

# Run specific test item
test-item item:
    just julia "@run_package_tests filter=ti->ti.name == String(:{{item}})"
"""

"""
    justfile()

Create or update a justfile with REPLicant integration recipes.

This function helps set up a project to use REPLicant by creating or updating
a justfile with useful recipes for executing Julia code, looking up documentation,
and running tests.

# Behavior
- If no justfile exists: Creates a new `justfile` with REPLicant recipes
- If a justfile exists without a `julia` recipe: Appends REPLicant recipes  
- If a justfile exists with a `julia` recipe: Throws an error to avoid conflicts

# Supported justfile names
Searches for and updates any of these filenames (in order of preference):
- `justfile`
- `Justfile`
- `.justfile`
- `Justfile.just`
- `.justfile.just`

# Recipes added
- `julia code`: Execute Julia code through REPLicant
- `docs binding`: Look up documentation for a Julia binding
- `test-all`: Run all package tests using TestItemRunner
- `test-item item`: Run a specific test item by name

# Example
```julia
julia> using REPLicant

julia> REPLicant.justfile()
[ Info: Created justfile with REPLicant recipes
```

# Notes
- The function operates in the current working directory
- Recipes assume REPLicant server is running with a `REPLICANT_PORT` file
- The `julia` recipe uses `printf` and `nc` (netcat) for communication
"""
function justfile()
    # Find existing justfile
    existing = _find_just_file(pwd())

    if existing === nothing
        # Create new justfile
        path = joinpath(pwd(), "justfile")
        write(path, JUSTFILE_RECIPES)
        @info "Created justfile with REPLicant recipes" path
    else
        # Read existing content
        content = read(existing, String)

        # Check if julia recipe already exists
        if _contains_julia_recipe(content)
            error("Justfile already contains a 'julia' recipe at $existing")
        else
            # Append our recipes
            open(existing, "a") do io
                # Add newline if file doesn't end with one
                if !isempty(content) && !endswith(content, '\n')
                    println(io)
                end
                println(io, "\n# REPLicant recipes")
                print(io, JUSTFILE_RECIPES)
            end
            @info "Added REPLicant recipes to Justfile" existing
        end
    end
end

function _contains_julia_recipe(content::String)
    # Check if content contains a julia recipe definition
    # Recipe format: "recipe_name:" at start of line
    lines = split(content, '\n')

    for line in lines
        # Skip comments and empty lines
        stripped = strip(line)
        if startswith(stripped, "#") || isempty(stripped)
            continue
        end

        # Check for julia recipe (with optional parameters)
        if occursin(r"^julia\s*(\s+\w+)*\s*:", line)
            return true
        end
    end

    return false
end

end # module REPLicant
