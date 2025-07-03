# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Usage
- `just julia "<code>"` - Execute Julia code through REPLicant (requires server running)
  - **Important**: When using strings in code, escape inner quotes: `just julia 'println(\"Hello world\")'`
  - Example: `just julia 'x = \"test\"; length(x)'`

### Testing
- `just test-all` - Run all tests using TestItemRunner
- `just test-item <item>` - Run a specific test item by name
- `just test-tag <tag>` - Run tests with a specific tag
- Tests are run using TestItemRunner framework - test files should use `@testitem` blocks

### Development
- `just format` - Format code (requires .ci/format.jl)
- `just changelog` - Generate changelog (requires .ci/changelog.jl)

## Architecture

REPLicant is a socket-based Julia code evaluation server that allows remote execution of Julia code:

1. **Server Component** (`src/REPLicant.jl`)
   - Creates a socket server that listens on a dynamic port (starting from 8000)
   - Writes the port number to `REPLICANT_PORT` file in the project directory
   - Accepts code strings from clients, evaluates them, and returns results
   - Integrates with Revise.jl for automatic code reloading via extension

2. **Revise Extension** (`ext/REPLicantReviseExt.jl`)
   - Provides automatic code reloading when Revise.jl is loaded
   - Checks revision queue before executing code and runs `revise()` if needed

3. **Client Interface** (`justfile`)
   - Uses netcat (`nc`) to send code to the server
   - Reads port from `REPLICANT_PORT` file to connect to the correct server instance

The server captures both stdout and return values using IOCapture, handles errors gracefully, and formats output similar to the Julia REPL.

## Metadata Inspection Commands

REPLicant includes powerful metadata inspection commands that help analyze Julia code:

### Basic Commands
- `#meta list [filter]` - List objects in current module (functions/types/variables/modules)
- `#meta info <name>` - Show detailed information about an object

### Performance Analysis
- `#meta typed <func> (<types>)` - Show type-inferred code
- `#meta warntype <func> (<types>)` - Analyze type stability
- `#meta optimize <func> (<types>)` - Comprehensive performance analysis
- `#meta llvm <func> (<types>)` - Show LLVM IR
- `#meta native <func> (<types>)` - Show native assembly

### Dependency Analysis
- `#meta deps <function>` - Show what a function calls
- `#meta callers <function>` - Show what calls a function
- `#meta graph <function>` - Display call graph
- `#meta uses <type>` - Show where a type is used

See `docs/metadata-inspection-commands.md` for detailed documentation.
