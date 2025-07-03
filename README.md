# REPLicant.jl

```
██████╗ ███████╗██████╗ ██╗     ██╗ ██████╗ █████╗ ███╗   ██╗████████╗
██╔══██╗██╔════╝██╔══██╗██║     ██║██╔════╝██╔══██╗████╗  ██║╚══██╔══╝
██████╔╝█████╗  ██████╔╝██║     ██║██║     ███████║██╔██╗ ██║   ██║
██╔══██╗██╔══╝  ██╔═══╝ ██║     ██║██║     ██╔══██║██║╚██╗██║   ██║
██║  ██║███████╗██║     ███████╗██║╚██████╗██║  ██║██║ ╚████║   ██║
╚═╝  ╚═╝╚══════╝╚═╝     ╚══════╝╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝
```

REPLicant provides a Julia socket server that enables running code from
CLI-based tools and coding agents. This allows for quick feedback loops to
allow tools such as Claude Code to execute Julia code without the overhead of
starting up a new Julia process each time.

## Overview

REPLicant creates a socket-based server that maintains a live Julia session,
allowing external tools to execute Julia code without repeatedly paying Julia's
startup cost. This is particularly useful for coding assistants, automation
tools, and any scenario where you need to run many small Julia snippets
quickly.

## Why REPLicant?

Julia can have significant startup latency for some tasks, making it
impractical for tools that need to execute many small code snippets.
Traditional approaches that spawn a new `julia` process for each execution
become prohibitively slow. REPLicant solves this by:

- Maintaining a persistent Julia session that stays warm
- Accepting code via socket connections for immediate execution
- Preserving state between executions within the same session
- Integrating with Revise.jl for automatic code reloading during development

## Installation

```julia
using Pkg
Pkg.add("https://github.com/MichaelHatherly/REPLicant.jl")
```

## Usage

A `justfile` is required in the root of your project for `Server` to start up
and correctly detect the project.

### Setting up your project

REPLicant provides a convenient function to set up or update your project's
`justfile` with useful recipes:

```julia
using REPLicant

# Create or update justfile with REPLicant recipes
REPLicant.justfile()
```

This will:
- Create a new `justfile` if none exists, or
- Append REPLicant recipes to an existing justfile (if it doesn't already have a `julia` recipe)
- Add recipes for:
  - `julia code`: Execute Julia code through REPLicant
  - `docs binding`: Look up documentation
  - `test-all`: Run all tests
  - `test-item item`: Run a specific test item (uses `#test-item` command)
  - `test-tag tags...`: Run tests with specific tags (uses `#test-tags` command)
  - `include-file file`: Include a Julia file (uses `#include-file` command)

The function supports all standard justfile naming conventions (`justfile`, `Justfile`, `.justfile`, etc.).

### Starting the Server

```julia
using REPLicant

# Start with default settings (max 100 concurrent connections)
server = REPLicant.Server()

# Or with custom connection limit
server = REPLicant.Server(; max_connections = 50)
```

The server will:

1. Start listening on an available port (beginning at 8000)
2. Create a `REPLICANT_PORT` file containing the port number
3. Log the connection details
4. Enforce connection limits to prevent resource exhaustion

### Executing Code

With the server running, you can execute Julia code from any CLI tool that
supports sending strings over TCP sockets. For example, you can use `nc` to
handle the socket communication.

```just
julia code:
    printf '%s' "{{code}}" | nc localhost $(cat REPLICANT_PORT)
```

```bash
just julia "@run_package_tests"
```

### Stopping the Server

```julia
close(server)
```

This will close the socket and clean up the `REPLICANT_PORT` file. When `julia`
is closed the server will automatically stop, so you can also just exit the
REPL and the server will shut down gracefully.

## How It Works

1. **Socket Server**: REPLicant creates a TCP server that listens for incoming
   connections
2. **Code Evaluation**: Received code strings are evaluated in the active
   module using `include_string`
3. **Output Capture**: Both stdout and return values are captured using
   IOCapture
4. **Error Handling**: Errors are caught and formatted similarly to the Julia
   REPL
5. **State Persistence**: The Julia session remains active between connections,
   preserving variables and loaded packages since it is a live REPL

## Custom Commands

REPLicant supports special command syntax that begins with `#`. These commands
provide additional functionality beyond simple code evaluation.

### Built-in Commands

REPLicant includes several built-in commands:

- `#include-file <path>` - Include a Julia file relative to the project root
  ```bash
  just julia "#include-file src/utilities.jl"
  ```

- `#test-item <name>` - Run a specific test item by name (requires TestItemRunner)
  ```bash
  just julia "#test-item my_test_case"
  ```

- `#test-tags <tag1> <tag2>...` - Run tests matching all specified tags
  ```bash
  just julia "#test-tags unit integration"
  ```

- `#meta <subcommand>` - Metadata inspection commands (see below for details)

### Metadata Inspection

REPLicant includes powerful metadata inspection commands for code analysis:

```bash
# List all objects in current module
just julia "#meta list"

# Get detailed info about a function
just julia "#meta info process_data"

# Analyze type stability
just julia "#meta warntype compute (Int, Float64)"

# Show function dependencies
just julia "#meta deps main_function"

# Display call graph
just julia "#meta graph entry_point"
```

See the [metadata inspection documentation](docs/metadata-inspection-commands.md) for the full list of available commands and their usage.

### Creating Custom Commands

You can register custom commands when starting the server:

```julia
using REPLicant

# Define custom commands
commands = Dict{String,Function}(
    # Simple command that echoes back the input
    "echo" => (code, id, mod) -> () -> "Echo: $code",
    
    # Command that evaluates code multiple times
    "repeat" => (code, id, mod) -> begin
        n, expr = split(code, ' ', limit=2)
        () -> [include_string(mod, expr, "REPL[$id]") for _ in 1:parse(Int, n)]
    end,
    
    # Command that modifies server state
    "load-pkg" => (code, id, mod) -> begin
        pkg = strip(code)
        () -> Core.eval(mod, Meta.parse("using $pkg"))
    end
)

# Start server with custom commands
server = REPLicant.Server(; commands)
```

Command functions receive three arguments:
- `code`: The command arguments as a string (everything after the command name)
- `id`: The request ID for logging
- `mod`: The active module context

The function must return a thunk (zero-argument function) that performs the
actual command action. The thunk's return value and any stdout output will be
captured and sent back to the client.

### Command Naming

- Command names must start with a lowercase letter and can contain lowercase letters and hyphens
- The regex pattern for valid commands is: `^#([a-z][a-z\-]+)\s+`
- Invalid command names will cause the line to be evaluated as regular Julia code

## Risks and Considerations

### Security

**REPLicant executes arbitrary code with full system access**

- Only run REPLicant in trusted environments
- The server has no authentication or authorization mechanisms
- Executed code has the same permissions as the Julia process

### Concurrency

- Each client connection is handled in a separate task
- Concurrent requests may interfere with each other's global state
- Connection limits prevent resource exhaustion (default: 100 concurrent connections)
- When at capacity, new connections receive: "ERROR: Server at capacity, please retry"

## Development

### Running Tests

```bash
just test-all
```

### Integration with Revise.jl

REPLicant automatically integrates with Revise.jl when available, allowing code
changes to be reflected without restarting the server.
