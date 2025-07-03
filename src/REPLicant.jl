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
import Printf: @sprintf
import InteractiveUtils: subtypes, code_warntype, code_llvm, code_native
import InteractiveUtils

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
                "meta" => _meta_command,
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

        try
            if result.error
                _error_message(buffer, result, id)
            else
                _echo_object(result.value) && _show_object(buffer, result, mod)
            end
        catch error
            return "$error, $result"
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

#
# Metadata inspection commands.
#

function _meta_command(code::AbstractString, id::Integer, mod::Module)
    parts = split(strip(code), ' ', limit = 3)
    subcommand = length(parts) >= 1 ? parts[1] : "list"
    args = length(parts) >= 2 ? join(parts[2:end], ' ') : ""

    if subcommand == "list"
        filter = strip(args)
        return () -> _meta_list(mod, filter)
    elseif subcommand == "info"
        object_name = strip(args)
        if isempty(object_name)
            return () -> "ERROR: Object name required. Usage: #meta info <object_name>"
        end
        return () -> _meta_info(mod, object_name)
    elseif subcommand == "typed"
        return _meta_typed_command(args, id, mod)
    elseif subcommand == "warntype"
        return _meta_warntype_command(args, id, mod)
    elseif subcommand == "llvm"
        return _meta_llvm_command(args, id, mod)
    elseif subcommand == "native"
        return _meta_native_command(args, id, mod)
    elseif subcommand == "optimize"
        return _meta_optimize_command(args, id, mod)
    elseif subcommand == "deps"
        return _meta_deps_command(args, id, mod)
    elseif subcommand == "callers"
        return _meta_callers_command(args, id, mod)
    elseif subcommand == "graph"
        return _meta_graph_command(args, id, mod)
    elseif subcommand == "uses"
        return _meta_uses_command(args, id, mod)
    else
        error(
            "Unknown meta subcommand: $subcommand. Available: list, info, typed, warntype, llvm, native, optimize, deps, callers, graph, uses",
        )
    end
end

function _meta_list(mod::Module, filter::AbstractString = "")
    io = IOBuffer()

    # Get all names in the module
    all_names = names(mod; all = true, imported = true)

    # Categorize objects
    functions = Tuple{Symbol,String}[]
    types = Tuple{Symbol,String}[]
    modules = Symbol[]
    variables = Tuple{Symbol,String,String}[]

    for name in all_names
        # Skip compiler-generated names
        startswith(string(name), "#") && continue

        # Skip if not defined
        isdefined(mod, name) || continue

        # Skip private names unless specifically requested
        if isempty(filter) && startswith(string(name), "_")
            continue
        end

        obj = getfield(mod, name)

        # Categorize based on type
        if isa(obj, Module) && obj !== mod
            push!(modules, name)
        elseif isa(obj, Type) && !(obj <: Function)
            # It's a type (but not a function type)
            type_info = _get_type_info(obj)
            push!(types, (name, type_info))
        elseif isa(obj, Function) || (isa(obj, Type) && obj <: Function)
            # It's a function or callable type
            sig_info = _get_function_signature(name, obj, mod)
            push!(functions, (name, sig_info))
        else
            # It's a variable
            type_str = string(typeof(obj))
            size_str = _get_size_string(obj)
            push!(variables, (name, type_str, size_str))
        end
    end

    # Apply filter if specified
    if !isempty(filter)
        filter_lower = lowercase(filter)
        if filter_lower in ["function", "functions"]
            types = empty!(types)
            modules = empty!(modules)
            variables = empty!(variables)
        elseif filter_lower in ["type", "types"]
            functions = empty!(functions)
            modules = empty!(modules)
            variables = empty!(variables)
        elseif filter_lower in ["module", "modules"]
            functions = empty!(functions)
            types = empty!(types)
            variables = empty!(variables)
        elseif filter_lower in ["variable", "variables", "var", "vars"]
            functions = empty!(functions)
            types = empty!(types)
            modules = empty!(modules)
        else
            return "Unknown filter: $filter. Available: functions, types, modules, variables"
        end
    end

    # Format header
    header_title = if isempty(filter)
        "Objects in $mod"
    else
        "$(uppercasefirst(filter)) in $mod"
    end
    println(io, format_section_header(header_title))

    # Sort each category
    sort!(functions; by = first)
    sort!(types; by = first)
    sort!(modules)
    sort!(variables; by = first)

    # Display functions
    if !isempty(functions)
        println(io, format_section_header("Functions", 2))
        println(io, format_count("Function", length(functions)))
        for (name, sig) in functions
            if isempty(sig)
                println(io, format_list_item("$name", indent_level = 1))
            else
                println(io, format_list_item("$name$sig", indent_level = 1))
            end
        end
    end

    # Display types
    if !isempty(types)
        println(io, format_section_header("Types", 2))
        println(io, format_count("Type", length(types)))
        for (name, info) in types
            println(io, format_list_item("$name $info", indent_level = 1))
        end
    end

    # Display modules
    if !isempty(modules)
        println(io, format_section_header("Modules", 2))
        println(io, format_count("Module", length(modules)))
        for name in modules
            println(io, format_list_item("$name", indent_level = 1))
        end
    end

    # Display variables
    if !isempty(variables)
        println(io, format_section_header("Variables", 2))
        println(io, format_count("Variable", length(variables)))
        for (name, type_str, size_str) in variables
            println(io, format_list_item("$name :: $type_str $size_str", indent_level = 1))
        end
    end

    # Summary
    if isempty(filter)
        println(io, format_section_header("Summary", 2))
        println(
            io,
            format_object_summary(
                length(functions),
                length(types),
                length(modules),
                length(variables),
            ),
        )
    end

    return String(take!(io))
end

function _get_function_signature(name::Symbol, obj, mod::Module)
    try
        meths = methods(obj)
        if isempty(meths)
            return "()"
        end

        # Get first method for display
        meth = first(meths)

        # Get location
        file, line = Base.functionloc(meth)
        if isnothing(file)
            location = "REPL"
        else
            location = _format_location(file, line)
        end

        # Get signature
        sig = meth.sig
        params = sig.parameters[2:end]  # Skip function type

        if isempty(params)
            sig_str = "()"
        else
            # Format parameter types
            param_strs = [string(T) for T in params]
            sig_str = "($(join(param_strs, ", ")))"
        end

        # Add method count if more than one
        if length(meths) > 1
            sig_str *= " +$(length(meths)-1) methods"
        end

        result = "$sig_str at $location"
        return result
    catch e
        # More detailed error handling
        @error "Failed to get signature for $name" exception = e
        return "()"  # Fallback for built-in functions
    end
end

function _get_type_info(T::Type)
    try
        if isabstracttype(T)
            super = supertype(T)
            return "<: $super (abstract)"
        else
            super = supertype(T)
            field_count = length(fieldnames(T))
            if field_count == 0
                return "<: $super"
            else
                return "<: $super with $field_count field$(field_count == 1 ? "" : "s")"
            end
        end
    catch
        return ":: Type"
    end
end

function _get_size_string(obj)
    try
        if isa(obj, AbstractArray)
            dims = size(obj)
            if length(dims) == 1
                return "($(dims[1]) elements)"
            else
                return "($(join(dims, "×")))"
            end
        elseif isa(obj, AbstractDict)
            n = length(obj)
            return "($(n) $(n == 1 ? "entry" : "entries"))"
        elseif isa(obj, AbstractString)
            n = length(obj)
            return "($(n) character$(n == 1 ? "" : "s"))"
        else
            return ""
        end
    catch
        return ""
    end
end

function _format_location(file::Union{AbstractString,Nothing}, line::Integer)
    # Handle nothing file
    if isnothing(file)
        return "unknown location"
    end

    # Handle REPL locations
    if occursin("REPL[", file)
        return file
    end

    # Try to make path relative to current directory
    try
        pwd_path = pwd()
        if startswith(file, pwd_path)
            rel_path = relpath(file, pwd_path)
            return "$rel_path:$line"
        end
    catch
    end

    # Try to shorten stdlib paths
    if occursin("julia", file) && occursin("stdlib", file)
        parts = split(file, "stdlib")
        if length(parts) >= 2
            return "stdlib" * parts[end] * ":$line"
        end
    end

    # Default: use full path
    return "$file:$line"
end

#
# Meta info commands.
#

function _meta_info(mod::Module, object_name::AbstractString)
    # Parse object name
    sym = Symbol(object_name)

    # Check if object exists
    if !isdefined(mod, sym)
        return "ERROR: Object '$object_name' not found in module $mod"
    end

    # Get the object
    obj = getfield(mod, sym)

    # Dispatch based on type
    if isa(obj, Module)
        return _meta_info_module(sym, obj, mod)
    elseif isa(obj, Type) && !(obj <: Function)
        return _meta_info_type(sym, obj, mod)
    elseif isa(obj, Function) || (isa(obj, Type) && obj <: Function)
        return _meta_info_function(sym, obj, mod)
    else
        return _meta_info_variable(sym, obj, mod)
    end
end

function _meta_info_function(name::Symbol, func, mod::Module)
    io = IOBuffer()

    # Header
    println(io, format_section_header("Function: $name"))

    # Get all methods
    meths = methods(func)

    # Methods section
    println(io, format_section_header("Signatures", 2))
    println(io, format_key_value("Methods", length(meths)))

    # List each method with location
    for (i, method) in enumerate(meths)
        file, line = Base.functionloc(method)
        location = isnothing(file) ? "unknown location" : _format_location(file, line)

        # Get signature
        sig = method.sig
        params = sig.parameters[2:end]  # Skip function type
        param_strs = String[]

        # Format parameters
        for T in params
            push!(param_strs, string(T))
        end

        sig_str = "$(name)($(join(param_strs, ", ")))"
        println(io, format_list_item("$sig_str at $location", indent_level = 1))
    end

    # Documentation
    doc = Base.Docs.doc(func)
    doc_str = string(doc)
    if !isempty(doc_str) && doc_str != "No documentation found."
        println(io, format_section_header("Documentation", 2))
        for line in split(doc_str, '\n')
            println(io, "  $line")
        end
    end

    # Properties section
    println(io, format_section_header("Properties", 2))
    println(io, format_key_value("Generic function", true, indent_level = 1))
    println(io, format_key_value("Module", parentmodule(func), indent_level = 1))

    return String(take!(io))
end

function _meta_info_type(name::Symbol, T::Type, mod::Module)
    io = IOBuffer()

    # Header
    println(io, "Type: $name")
    println(io, "="^(6 + length(string(name))))

    # Type hierarchy
    println(io, "\nSupertype: $(supertype(T))")

    # Check if abstract
    if isabstracttype(T)
        println(io, "Abstract: true")

        # Show subtypes if any
        subs = subtypes(T)
        if !isempty(subs)
            println(io, "\nSubtypes: $(length(subs))")
            for (i, sub) in enumerate(subs)
                if i <= 10  # Show first 10
                    println(io, "  - $sub")
                end
            end
            if length(subs) > 10
                println(io, "  ... and $(length(subs) - 10) more")
            end
        end
    else
        println(io, "Abstract: false")

        # Fields
        fnames = fieldnames(T)
        ftypes = fieldtypes(T)
        println(io, "\nFields: $(length(fnames))")
        if !isempty(fnames)
            for (fname, ftype) in zip(fnames, ftypes)
                println(io, "  $fname :: $ftype")
            end
        end

        # Constructors
        constructors = methods(T)
        if length(constructors) > 0
            println(io, "\nConstructors: $(length(constructors))")
            for (i, method) in enumerate(constructors)
                if i <= 5  # Show first 5
                    sig = method.sig
                    params = sig.parameters[2:end]
                    param_strs = [string(T) for T in params]
                    println(io, "  $name($(join(param_strs, ", ")))")
                end
            end
            if length(constructors) > 5
                println(io, "  ... and $(length(constructors) - 5) more")
            end
        end
    end

    # Size if concrete
    if isconcretetype(T)
        println(io, "\nSize: $(sizeof(T)) bytes")
    end

    # Documentation
    doc = Base.Docs.doc(T)
    doc_str = string(doc)
    if !isempty(doc_str) && doc_str != "No documentation found."
        println(io, "\nDocumentation:")
        for line in split(doc_str, '\n')
            println(io, "  ", line)
        end
    end

    return String(take!(io))
end

function _meta_info_module(name::Symbol, mod::Module, parent_mod::Module)
    io = IOBuffer()

    # Header
    println(io, "Module: $name")
    println(io, "="^(8 + length(string(name))))

    # Parent module
    println(io, "\nParent: $(parentmodule(mod))")

    # Count contents
    all_names = names(mod; all = true, imported = false)
    exported = names(mod; all = false)

    # Exports
    println(io, "\nExports: $(length(exported))")
    if !isempty(exported)
        # Group by type
        exp_funcs = Symbol[]
        exp_types = Symbol[]
        exp_other = Symbol[]

        for exp in exported
            if isdefined(mod, exp)
                obj = getfield(mod, exp)
                if isa(obj, Function) || (isa(obj, Type) && obj <: Function)
                    push!(exp_funcs, exp)
                elseif isa(obj, Type)
                    push!(exp_types, exp)
                else
                    push!(exp_other, exp)
                end
            end
        end

        if !isempty(exp_funcs)
            println(io, "  Functions:")
            for f in exp_funcs[1:min(10, length(exp_funcs))]
                println(io, "    - $f")
            end
            if length(exp_funcs) > 10
                println(io, "    ... and $(length(exp_funcs) - 10) more")
            end
        end

        if !isempty(exp_types)
            println(io, "  Types:")
            for t in exp_types[1:min(10, length(exp_types))]
                println(io, "    - $t")
            end
            if length(exp_types) > 10
                println(io, "    ... and $(length(exp_types) - 10) more")
            end
        end

        if !isempty(exp_other)
            println(io, "  Other:")
            for o in exp_other[1:min(10, length(exp_other))]
                println(io, "    - $o")
            end
            if length(exp_other) > 10
                println(io, "    ... and $(length(exp_other) - 10) more")
            end
        end
    end

    println(io, "\nTotal names: $(length(all_names))")

    # Path if it's a package
    if isdefined(mod, :__file__)
        println(io, "File: $(mod.__file__)")
    end

    # Documentation
    doc = Base.Docs.doc(mod)
    doc_str = string(doc)
    if !isempty(doc_str) && doc_str != "No documentation found."
        println(io, "\nDocumentation:")
        for line in split(doc_str, '\n')
            println(io, "  ", line)
        end
    end

    return String(take!(io))
end

function _meta_info_variable(name::Symbol, obj, mod::Module)
    io = IOBuffer()

    # Header
    println(io, "Variable: $name")
    println(io, "="^(10 + length(string(name))))

    # Type
    T = typeof(obj)
    println(io, "\nType: $T")

    # Size information
    try
        size_bytes = Base.summarysize(obj)
        println(io, "Size: $(format_bytes(size_bytes))")
    catch
        # Some objects can't be sized
    end

    # Special handling for collections
    if isa(obj, AbstractArray)
        println(io, "\nArray information:")
        println(io, "  Dimensions: $(join(size(obj), " × "))")
        println(io, "  Element type: $(eltype(obj))")
        println(io, "  Total elements: $(length(obj))")

        # Show first few elements if small
        if length(obj) <= 10
            println(io, "  Values: ", obj)
        end
    elseif isa(obj, AbstractDict)
        println(io, "\nDictionary information:")
        println(io, "  Entries: $(length(obj))")
        println(io, "  Key type: $(keytype(obj))")
        println(io, "  Value type: $(valtype(obj))")

        # Show first few entries if small
        if length(obj) <= 5
            println(io, "  Contents:")
            for (k, v) in obj
                println(io, "    $k => $v")
            end
        end
    elseif isa(obj, AbstractString)
        println(io, "\nString information:")
        println(io, "  Length: $(length(obj)) characters")
        if length(obj) <= 200
            println(io, "  Content: \"$obj\"")
        else
            println(io, "  Preview: \"$(first(obj, 100))...\"")
        end
    elseif isa(obj, AbstractSet)
        println(io, "\nSet information:")
        println(io, "  Elements: $(length(obj))")
        println(io, "  Element type: $(eltype(obj))")

        if length(obj) <= 10
            println(io, "  Contents: ", obj)
        end
    end

    # Show value for simple types
    if isa(obj, Number) || isa(obj, Symbol) || isa(obj, Bool)
        println(io, "\nValue: $obj")
    end

    # Check if mutable
    println(io, "\nMutable: $(ismutable(obj))")

    return String(take!(io))
end

# Helper function to format bytes
function format_bytes(bytes::Integer)
    if bytes < 1024
        return "$bytes bytes"
    elseif bytes < 1024^2
        return @sprintf("%.2f KB", bytes / 1024)
    elseif bytes < 1024^3
        return @sprintf("%.2f MB", bytes / 1024^2)
    else
        return @sprintf("%.2f GB", bytes / 1024^3)
    end
end

#
# Performance introspection functions.
#

function _parse_call_expression(expr_str::String, mod::Module)
    # Parse "funcname (Type1, Type2, ...)"
    m = match(r"^\s*(\w+)\s*\((.*)\)\s*$", expr_str)
    if isnothing(m)
        error("Invalid syntax. Use: #meta typed funcname (Type1, Type2, ...)")
    end

    func_name = Symbol(m[1])
    args_str = m[2]

    # Parse argument types
    if isempty(strip(args_str))
        arg_types = Tuple{}
    else
        # Evaluate each type in the module context
        type_exprs = split(args_str, ',')
        types = []
        for t in type_exprs
            stripped = strip(t)
            if !isempty(stripped)
                type_expr = Meta.parse(stripped)
                type_val = Core.eval(mod, type_expr)
                push!(types, type_val)
            end
        end
        # Create the tuple type properly
        arg_types = Tuple{types...}
    end

    return func_name, arg_types
end

function _meta_typed_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        if !isdefined(mod, func_name)
            error("Function $func_name not found")
        end

        func = getfield(mod, func_name)

        # Get typed code
        code_info = Base.code_typed(func, arg_types; optimize = true)

        if isempty(code_info)
            return "No methods match the given argument types"
        end

        io = IOBuffer()
        println(io, format_section_header("Type-inferred code for $func_name$arg_types"))

        # Show the typed code
        for (i, (ci, ret_type)) in enumerate(code_info)
            if length(code_info) > 1
                println(io, format_section_header("Method $i", 2))
            end
            println(io, format_key_value("Return type", ret_type))
            println(io)

            # Display code with line numbers
            Base.IRShow.show_ir(io, ci)
        end

        String(take!(io))
    end
end

function _meta_warntype_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)

        io = IOBuffer()
        println(
            io,
            format_section_header("Type stability analysis for $func_name$arg_types"),
        )
        println(io)

        # Use InteractiveUtils.code_warntype
        try
            # Import code_warntype from InteractiveUtils
            InteractiveUtils.code_warntype(io, func, arg_types)
        catch e
            println(io, "ERROR: Failed to analyze function: ", e)
        end

        output = String(take!(io))
        io = IOBuffer()

        # Post-process to highlight issues
        _highlight_type_instabilities(output, io)
    end
end

function _highlight_type_instabilities(output::String, io::IO = IOBuffer())
    # Track issues found
    issues = String[]

    for line in split(output, '\n')
        # Highlight Any types (both lowercase and uppercase)
        if (occursin("::Any", line) || occursin("::ANY", line)) &&
           !occursin("Body::Any", line) &&
           !occursin("Body::ANY", line)
            push!(issues, "Type instability: " * strip(line))
        end

        # Check for Body::ANY or Body::UNION
        if occursin("Body::ANY", line)
            push!(issues, "Return type is unstable (Any)")
        elseif occursin("Body::UNION", line)
            push!(issues, "Return type is unstable (Union)")
        end

        # Highlight problematic Union types
        if occursin("::Union{", line) && !occursin("::Union{}", line)
            push!(issues, "Union type: " * strip(line))
        end

        # Highlight boxing
        if occursin("Box(", line)
            push!(issues, "Boxing allocation: " * strip(line))
        end

        println(io, line)
    end

    # Add summary at the end
    if !isempty(issues)
        println(io, format_section_header("Type Stability Issues", 2))
        for issue in issues
            println(io, format_list_item(issue, indent_level = 1, bullet = "⚠"))
        end
        println(io, format_section_header("Optimization Suggestions", 2))
        println(
            io,
            format_list_item(
                "Add type annotations to unstable variables",
                indent_level = 1,
            ),
        )
        println(
            io,
            format_list_item("Ensure function returns consistent types", indent_level = 1),
        )
        println(
            io,
            format_list_item(
                "Avoid type-unstable operations in hot loops",
                indent_level = 1,
            ),
        )
    else
        println(io, format_status("No type stability issues detected", :success))
    end

    String(take!(io))
end

function _meta_llvm_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)

        io = IOBuffer()
        println(io, format_section_header("LLVM IR for $func_name$arg_types"))
        println(io)

        # Get LLVM code using InteractiveUtils.code_llvm
        try
            InteractiveUtils.code_llvm(io, func, arg_types; debuginfo = :none)
        catch e
            println(io, "ERROR: Failed to generate LLVM code: ", e)
        end

        output = String(take!(io))
        io = IOBuffer()

        # Add analysis
        _analyze_llvm_output(output, io)
    end
end

function _analyze_llvm_output(llvm::String, io::IO)
    println(io, llvm)

    println(io, format_section_header("LLVM Analysis", 2))

    # Count allocations
    allocs = count("alloca", llvm)
    calls = count("call", llvm)

    println(io, format_key_value("Stack allocations", allocs))
    println(io, format_key_value("Function calls", calls))

    # Check for heap allocations
    if occursin("julia.gc_alloc", llvm)
        println(io, format_status("Heap allocations detected", :warning))
    end

    # Check for bounds checks
    if occursin("julia.bounds_check", llvm)
        println(io, format_status("Bounds checks present (use @inbounds to remove)", :info))
    end

    String(take!(io))
end

function _meta_native_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)

        io = IOBuffer()
        println(io, format_section_header("Native assembly for $func_name$arg_types"))
        println(io)

        # Get native code using InteractiveUtils.code_native
        try
            InteractiveUtils.code_native(io, func, arg_types; debuginfo = :none)
        catch e
            println(io, "ERROR: Failed to generate native code: ", e)
        end
        String(take!(io))
    end
end

function _meta_optimize_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)
        io = IOBuffer()

        println(io, format_section_header("Performance Analysis: $func_name$arg_types"))

        # 1. Type inference results
        println(io, format_section_header("Type Inference", 2))
        code_info = Base.code_typed(func, arg_types; optimize = true)
        if !isempty(code_info)
            ci, ret_type = code_info[1]
            println(io, format_key_value("Return type", ret_type, indent_level = 1))

            # Check for type stability
            stable = ret_type != Any && !isa(ret_type, Union)
            status_msg =
                stable ? format_status("Yes", :success) : format_status("No", :error)
            println(io, format_key_value("Type stable", status_msg, indent_level = 1))
        end

        # 2. Identify allocations and instabilities
        println(io, format_section_header("Performance Issues", 2))

        # Run code_warntype analysis
        warntype_io = IOBuffer()
        try
            InteractiveUtils.code_warntype(warntype_io, func, arg_types)
        catch e
            println(warntype_io, "ERROR: Failed to analyze function: ", e)
        end
        warntype_output = String(take!(warntype_io))

        issues = _extract_performance_issues(warntype_output)

        if isempty(issues)
            println(io, format_status("No major performance issues detected", :success))
        else
            println(io, format_count("Issue", length(issues)))
            for issue in issues
                println(io, format_list_item("$issue", indent_level = 1))
            end
        end

        # 3. Optimization suggestions
        println(io, format_section_header("Optimization Suggestions", 2))
        suggestions = _generate_optimization_suggestions(issues, warntype_output)

        if isempty(suggestions)
            println(io, format_status("No specific suggestions available", :info))
        else
            for suggestion in suggestions
                println(io, format_list_item("$suggestion", indent_level = 1))
            end
        end

        # 4. Allocation summary
        println(io, format_section_header("Memory Analysis", 2))
        println(
            io,
            format_key_value(
                "Note",
                "Run @allocated $func_name(...) for allocation data",
                indent_level = 1,
            ),
        )

        String(take!(io))
    end
end

function _extract_performance_issues(warntype_output::String)
    issues = String[]

    for line in split(warntype_output, '\n')
        # Type instabilities (handle both Any and ANY)
        if (occursin("::Any", line) || occursin("::ANY", line)) &&
           !occursin("Body::Any", line) &&
           !occursin("Body::ANY", line)
            m = match(r"(\w+)::(Any|ANY)", line)
            if !isnothing(m)
                push!(issues, "Variable '$(m[1])' has unstable type Any")
            end
        end

        # Check for unstable return type
        if occursin("Body::ANY", line)
            push!(issues, "Function returns unstable type (Any)")
        elseif occursin("Body::UNION", line)
            push!(issues, "Function returns unstable type (Union)")
        end

        # Union types
        if occursin("::Union{", line)
            m = match(r"(\w+)::Union{([^}]+)}", line)
            if !isnothing(m)
                push!(issues, "Variable '$(m[1])' has union type: Union{$(m[2])}")
            end
        end

        # Boxing
        if occursin("%box", line) || occursin("Box(", line)
            push!(issues, "Boxing allocation detected: $line")
        end
    end

    unique!(issues)
    return issues
end

function _generate_optimization_suggestions(issues::Vector{String}, warntype_output::String)
    suggestions = String[]

    # Type instability suggestions
    if any(occursin("unstable type Any", issue) for issue in issues)
        push!(suggestions, "Add type assertions or ensure consistent return types")
        push!(
            suggestions,
            "Consider splitting polymorphic code into separate type-stable functions",
        )
    end

    # Union type suggestions
    if any(occursin("union type", issue) for issue in issues)
        push!(suggestions, "Avoid mixing Nothing/Missing with other types in hot code")
        push!(suggestions, "Use Union splitting or handle cases separately")
    end

    # Allocation suggestions
    if any(occursin("Boxing allocation", issue) for issue in issues)
        push!(suggestions, "Avoid capturing variables that change type in closures")
        push!(suggestions, "Pre-allocate arrays and reuse buffers")
    end

    # General suggestions based on patterns
    if occursin("@inbounds", warntype_output)
        push!(suggestions, "Consider using @inbounds after validating array access")
    end

    if occursin("AbstractArray", warntype_output) ||
       occursin("AbstractVector", warntype_output)
        push!(
            suggestions,
            "Use concrete array types in function signatures for better performance",
        )
    end

    return suggestions
end

#
# Formatting utilities for consistent output.
#

# Section separators and status indicators
const MAJOR_SEP = "="
const MINOR_SEP = "-"
const CHECK = "✓"
const CROSS = "✗"
const WARN = "⚠"
const INFO = "ℹ"
const INDENT = "  "

# Format a section header with appropriate separator
function format_section_header(title::String, level::Int = 1)
    if level == 1
        sep_len = max(20, length(title) + 4)
        return "$title\n$(MAJOR_SEP^sep_len)"
    elseif level == 2
        return "\n## $title"
    else
        return "\n$title:"
    end
end

# Format a key-value pair with optional indentation
function format_key_value(key::String, value::Any; indent_level::Int = 0)
    indent = INDENT^indent_level
    return "$indent$key: $value"
end

# Format a list item with bullet and indentation
function format_list_item(item::String; indent_level::Int = 0, bullet::String = "-")
    indent = INDENT^indent_level
    if isempty(bullet)
        return "$indent$item"
    else
        return "$indent$bullet $item"
    end
end

# Format status message with appropriate indicator
function format_status(message::String, status::Symbol = :info)
    indicator = if status == :success
        CHECK
    elseif status == :error
        CROSS
    elseif status == :warning
        WARN
    else
        INFO
    end
    return "$indicator $message"
end

# Format a count with category
function format_count(category::String, count::Int; plural_suffix::String = "s")
    if count == 1
        return "$category ($count):"
    else
        # Handle special plurals like "ies" for words ending in "y"
        if plural_suffix == "ies" && endswith(category, "y")
            plural_form = category[1:(end-1)] * "ies"
        else
            plural_form = category * plural_suffix
        end
        return "$plural_form ($count):"
    end
end

# Truncate long outputs with informative message
function truncate_output(str::String; max_lines::Int = 50, max_chars::Int = 2000)
    lines = split(str, '\n')

    if length(lines) > max_lines
        truncated = join(lines[1:max_lines], '\n')
        return truncated * "\n... ($(length(lines) - max_lines) more lines)"
    elseif length(str) > max_chars
        return str[1:max_chars] * "\n... ($(length(str) - max_chars) more characters)"
    else
        return str
    end
end

# Format error message with context and suggestions
function format_error_message(
    error_type::String,
    message::String,
    suggestions::Vector{String} = String[],
)
    io = IOBuffer()
    println(io, "ERROR: $error_type")
    println(io, "  $message")

    if !isempty(suggestions)
        println(io, "\nSuggestions:")
        for suggestion in suggestions
            println(io, "  - $suggestion")
        end
    end

    return String(take!(io))
end

# Format object summary with counts
function format_object_summary(funcs::Int, types::Int, modules::Int, vars::Int)
    total = funcs + types + modules + vars
    parts = String[]

    funcs > 0 && push!(parts, "$funcs function$(funcs == 1 ? "" : "s")")
    types > 0 && push!(parts, "$types type$(types == 1 ? "" : "s")")
    modules > 0 && push!(parts, "$modules module$(modules == 1 ? "" : "s")")
    vars > 0 && push!(parts, "$vars variable$(vars == 1 ? "" : "s")")

    if isempty(parts)
        return "Total: 0 objects"
    else
        return "Total: $total objects ($(join(parts, ", ")))"
    end
end

#
# Dependency analysis functions.
#

function _extract_dependencies(func::Function, types::Type)
    deps = Set{String}()

    # Get lowered code
    try
        code = Base.code_lowered(func, types)

        for method_code in code
            _extract_calls_from_code(method_code, deps)
        end
    catch
        # Some methods might not be analyzable
    end

    return sort(collect(deps))
end

function _extract_calls_from_code(code::Core.CodeInfo, deps::Set{String})
    for stmt in code.code
        if isa(stmt, Expr)
            _extract_calls_from_expr(stmt, deps)
        elseif isa(stmt, GlobalRef)
            # Handle GlobalRef directly
            push!(deps, "$(stmt.mod).$(stmt.name)")
        end
    end
end

function _extract_calls_from_expr(expr::Expr, deps::Set{String})
    if expr.head == :call
        # Direct function call
        if length(expr.args) >= 1
            func_expr = expr.args[1]

            if isa(func_expr, GlobalRef)
                # Fully qualified call
                push!(deps, "$(func_expr.mod).$(func_expr.name)")
            elseif isa(func_expr, Symbol)
                # Local or imported call
                push!(deps, string(func_expr))
            elseif isa(func_expr, Expr) && func_expr.head == :.
                # Dot call like Module.func
                push!(deps, string(func_expr))
            end
        end
    elseif expr.head in [:invoke, :foreigncall]
        # Handle special call types
        if expr.head == :invoke && length(expr.args) >= 2
            meth = expr.args[1]
            if isa(meth, Core.MethodInstance)
                push!(deps, string(meth.def.name))
            end
        end
    end

    # Recurse into sub-expressions
    for arg in expr.args
        if isa(arg, Expr)
            _extract_calls_from_expr(arg, deps)
        end
    end
end

function _meta_deps_command(func_name::String, id::Integer, mod::Module)
    return () -> begin
        sym = Symbol(strip(func_name))

        if !isdefined(mod, sym)
            return "ERROR: Function $func_name not found in module $mod"
        end

        obj = getfield(mod, sym)
        if !isa(obj, Function) && !(isa(obj, Type) && obj <: Function)
            return "ERROR: $func_name is not a function"
        end

        io = IOBuffer()
        println(io, format_section_header("Dependencies of $func_name"))
        println(io)

        # Get all methods
        meths = methods(obj)

        all_deps = Dict{String,Vector{String}}()

        for meth in meths
            try
                sig = meth.sig
                # Handle UnionAll types by getting the body
                sig_type = sig isa UnionAll ? sig.body : sig
                types = Tuple{sig_type.parameters[2:end]...}

                deps = _extract_dependencies(obj, types)

                sig_str = _format_method_signature(meth)
                all_deps[sig_str] = deps
            catch e
                # Skip methods that can't be analyzed
                continue
            end
        end

        # Display dependencies by method
        for (sig, deps) in all_deps
            println(io, format_section_header("Method: $sig", 3))
            if isempty(deps)
                println(io, format_status("No dependencies detected", :info))
            else
                println(io, format_count("Dependency", length(deps), plural_suffix = "ies"))
                for dep in deps
                    # Try to get location info
                    loc = _try_get_location(dep, mod)
                    if isnothing(loc)
                        println(io, format_list_item("$dep", indent_level = 1))
                    else
                        println(io, format_list_item("$dep at $loc", indent_level = 1))
                    end
                end
            end
        end

        # Summary
        all_unique_deps = union(values(all_deps)...)
        println(io, format_section_header("Summary", 2))
        println(io, format_key_value("Total unique dependencies", length(all_unique_deps)))

        String(take!(io))
    end
end

function _format_method_signature(meth::Method)
    sig = meth.sig
    # Handle UnionAll types by getting the body
    sig_type = sig isa UnionAll ? sig.body : sig
    params = sig_type.parameters[2:end]  # Skip function type
    param_strs = [string(T) for T in params]
    return "$(meth.name)($(join(param_strs, ", ")))"
end

function _try_get_location(dep::String, mod::Module)
    # Try to parse the dependency and find its location
    parts = split(dep, '.')

    try
        if length(parts) >= 2
            # Module.function format
            mod_name = Symbol(parts[1])
            func_name = Symbol(parts[end])

            if isdefined(Main, mod_name)
                target_mod = getfield(Main, mod_name)
                if isdefined(target_mod, func_name)
                    func = getfield(target_mod, func_name)
                    if isa(func, Function)
                        meths = methods(func)
                        if !isempty(meths)
                            file, line = Base.functionloc(first(meths))
                            return _format_location(file, line)
                        end
                    end
                end
            end
        else
            # Simple function name
            func_name = Symbol(dep)
            if isdefined(mod, func_name)
                func = getfield(mod, func_name)
                if isa(func, Function)
                    meths = methods(func)
                    if !isempty(meths)
                        file, line = Base.functionloc(first(meths))
                        return _format_location(file, line)
                    end
                end
            end
        end
    catch
        # Failed to resolve location
    end

    return nothing
end

function _meta_callers_command(func_name::String, id::Integer, mod::Module)
    return () -> begin
        target_sym = Symbol(strip(func_name))

        if !isdefined(mod, target_sym)
            return "ERROR: Function $func_name not found in module $mod"
        end

        io = IOBuffer()
        println(io, format_section_header("Functions that call $func_name"))
        println(io)

        callers = Set{String}()

        # Search through all functions in module
        for name in names(mod; all = true)
            isdefined(mod, name) || continue

            # Skip compiler-generated names
            startswith(string(name), "#") && continue

            obj = getfield(mod, name)

            (isa(obj, Function) || (isa(obj, Type) && obj <: Function)) || continue

            # Skip self
            name == target_sym && continue

            # Check if this function calls our target
            if _function_calls_target(obj, target_sym, mod)
                push!(callers, string(name))
            end
        end

        if isempty(callers)
            println(io, format_status("No callers found in module $mod", :info))
        else
            println(io, format_count("Caller", length(callers)))
            for caller in sort(collect(callers))
                # Get location
                caller_func = getfield(mod, Symbol(caller))
                meths = methods(caller_func)
                if !isempty(meths)
                    file, line = Base.functionloc(first(meths))
                    location = _format_location(file, line)
                    println(io, format_list_item("$caller at $location", indent_level = 1))
                else
                    println(io, format_list_item("$caller", indent_level = 1))
                end
            end
        end

        println(io, format_section_header("Summary", 2))
        println(io, format_key_value("Total callers", length(callers)))

        String(take!(io))
    end
end

function _function_calls_target(func::Function, target::Symbol, mod::Module)
    for meth in methods(func)
        try
            sig = meth.sig
            # Handle UnionAll types by getting the body
            sig_type = sig isa UnionAll ? sig.body : sig
            types = Tuple{sig_type.parameters[2:end]...}

            code = Base.code_lowered(func, types)
            for method_code in code
                if _code_contains_call(method_code, target)
                    return true
                end
            end
        catch
            # Some methods might not be analyzable
            continue
        end
    end
    return false
end

function _code_contains_call(code::Core.CodeInfo, target::Symbol)
    for stmt in code.code
        if isa(stmt, Expr) && _expr_contains_call(stmt, target)
            return true
        elseif isa(stmt, GlobalRef)
            # Check if this is a direct call to the target
            if stmt.name == target
                return true
            end
        end
    end
    return false
end

function _expr_contains_call(expr::Expr, target::Symbol)
    if expr.head == :call && length(expr.args) >= 1
        func_expr = expr.args[1]

        if func_expr == target
            return true
        elseif isa(func_expr, GlobalRef) && func_expr.name == target
            return true
        elseif isa(func_expr, Expr) && func_expr.head == :. && length(func_expr.args) >= 2
            # Check for Module.target calls
            if func_expr.args[2] isa QuoteNode && func_expr.args[2].value == target
                return true
            end
        end
    end

    # Recurse into sub-expressions
    for arg in expr.args
        if isa(arg, Expr) && _expr_contains_call(arg, target)
            return true
        end
    end

    return false
end

function _meta_graph_command(func_name::String, id::Integer, mod::Module)
    return () -> begin
        sym = Symbol(strip(func_name))

        if !isdefined(mod, sym)
            return "ERROR: Function $func_name not found in module $mod"
        end

        io = IOBuffer()
        println(io, format_section_header("Call graph starting from $func_name"))
        println(io)

        # Build graph with depth limit
        visited = Set{String}()
        graph = Dict{String,Vector{String}}()

        _build_call_graph(sym, mod, graph, visited, 0, 3)

        # Display as simple tree
        _print_simple_call_tree(io, string(sym), graph, "", Set{String}())

        println(io, format_section_header("Summary", 2))
        println(io, format_key_value("Nodes in graph", length(graph)))

        String(take!(io))
    end
end

function _build_call_graph(
    func_sym::Symbol,
    mod::Module,
    graph::Dict,
    visited::Set,
    depth::Int,
    max_depth::Int,
)
    func_name = string(func_sym)

    # Avoid cycles and depth limit
    if func_name in visited || depth >= max_depth
        return
    end

    push!(visited, func_name)

    if isdefined(mod, func_sym)
        obj = getfield(mod, func_sym)
        if isa(obj, Function) || (isa(obj, Type) && obj <: Function)
            deps = String[]

            # Get dependencies for all methods
            for meth in methods(obj)
                try
                    sig = meth.sig
                    # Handle UnionAll types by getting the body
                    sig_type = sig isa UnionAll ? sig.body : sig
                    types = Tuple{sig_type.parameters[2:end]...}
                    method_deps = _extract_dependencies(obj, types)
                    append!(deps, method_deps)
                catch e
                    # Skip methods that can't be analyzed
                    continue
                end
            end

            unique!(deps)
            graph[func_name] = deps

            # Recurse
            for dep in deps
                dep_sym = _parse_function_name(dep, mod)
                if !isnothing(dep_sym)
                    _build_call_graph(dep_sym, mod, graph, visited, depth + 1, max_depth)
                end
            end
        end
    end
end

function _parse_function_name(dep::String, mod::Module)
    # Extract function name from dependency string
    parts = split(dep, '.')

    try
        if length(parts) >= 2
            # Module.function format - get just the function name
            return Symbol(parts[end])
        else
            # Simple function name
            return Symbol(dep)
        end
    catch
        return nothing
    end
end

function _print_simple_call_tree(
    io::IO,
    node::String,
    graph::Dict,
    prefix::String,
    visited::Set{String},
)
    # Avoid printing cycles
    if node in visited
        println(io, prefix, "└─ ", node, " [circular]")
        return
    end

    push!(visited, node)
    println(io, prefix, "└─ ", node)

    if haskey(graph, node)
        children = graph[node]
        for (i, child) in enumerate(children)
            is_last = i == length(children)
            child_prefix = prefix * (is_last ? "   " : "│  ")

            # Display dependency directly without recursion
            child_name = split(child, '.')[end]
            println(io, child_prefix, "└─ ", child_name)
        end
    end

    delete!(visited, node)
end

function _meta_uses_command(type_name::String, id::Integer, mod::Module)
    return () -> begin
        sym = Symbol(strip(type_name))

        if !isdefined(mod, sym)
            return "ERROR: Type $type_name not found in module $mod"
        end

        obj = getfield(mod, sym)
        if !isa(obj, Type)
            return "ERROR: $type_name is not a type"
        end

        io = IOBuffer()
        println(io, format_section_header("Usage of type $type_name"))

        # Find functions that use this type
        println(io, format_section_header("Functions with $type_name in signature", 2))
        functions_using = _find_functions_using_type(obj, mod)

        if isempty(functions_using)
            println(io, format_status("None found", :info))
        else
            println(io, format_count("Function", length(functions_using)))
            for (func_name, usage_type) in functions_using
                println(io, format_list_item("$func_name ($usage_type)", indent_level = 1))
            end
        end

        # Find types that contain this type
        println(io, format_section_header("Types containing $type_name", 2))
        types_containing = _find_types_containing(obj, mod)

        if isempty(types_containing)
            println(io, format_status("None found", :info))
        else
            println(io, format_count("Type", length(types_containing)))
            for type_info in types_containing
                println(io, format_list_item("$type_info", indent_level = 1))
            end
        end

        String(take!(io))
    end
end

function _find_functions_using_type(T::Type, mod::Module)
    results = Tuple{String,String}[]

    for name in names(mod; all = true)
        isdefined(mod, name) || continue

        # Skip compiler-generated names
        startswith(string(name), "#") && continue

        obj = getfield(mod, name)

        if isa(obj, Function) || (isa(obj, Type) && obj <: Function)
            for meth in methods(obj)
                # Check parameters
                for (i, param_type) in enumerate(meth.sig.parameters[2:end])
                    if _type_uses_type(param_type, T)
                        push!(results, (string(name), "argument $i"))
                        break
                    end
                end

                # Check return type if available
                # This is harder to do statically, would need type inference
            end
        end
    end

    return unique(results)
end

function _type_uses_type(haystack::Type, needle::Type)
    if haystack == needle
        return true
    elseif haystack isa UnionAll
        return _type_uses_type(haystack.body, needle)
    elseif haystack isa Union
        return any(t -> _type_uses_type(t, needle), Base.uniontypes(haystack))
    elseif haystack <: Tuple
        return any(t -> _type_uses_type(t, needle), haystack.parameters)
    elseif haystack <: Array && length(haystack.parameters) > 0
        return _type_uses_type(haystack.parameters[1], needle)
    end
    return false
end

function _find_types_containing(T::Type, mod::Module)
    results = String[]

    for name in names(mod; all = true)
        isdefined(mod, name) || continue

        # Skip compiler-generated names
        startswith(string(name), "#") && continue

        obj = getfield(mod, name)

        if isa(obj, Type) && !(obj <: Function) && isconcretetype(obj)
            # Check fields
            for (fname, ftype) in zip(fieldnames(obj), fieldtypes(obj))
                if _type_uses_type(ftype, T)
                    push!(results, "$name.$fname :: $ftype")
                end
            end
        end
    end

    return results
end

end # module REPLicant
