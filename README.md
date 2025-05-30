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
  - `test-item item`: Run a specific test item

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
