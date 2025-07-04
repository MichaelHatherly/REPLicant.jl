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

## Code Organization

### File Structure
REPLicant follows a modular design with source files organized by functionality:

- **Main module** (`src/REPLicant.jl`) - Module definition, imports, and includes only
- **Server** (`src/server.jl`) - Socket server implementation and client handling
- **Evaluation** (`src/evaluation.jl`) - Code evaluation and command dispatch
- **Metadata commands** (`src/metadata_commands.jl`) - All #meta command implementations
- **Metadata helpers** (`src/metadata_helpers.jl`) - Helper functions for metadata inspection
- **Formatting** (`src/formatting.jl`) - Output formatting utilities
- **Justfile support** (`src/justfile_support.jl`) - Justfile integration
- **Filesystem** (`src/filesystem.jl`) - File system utilities

### Code Style Guidelines
- **Keep files focused and manageable** - Each file should have a single, clear purpose
- **Target 200-500 lines per file** - Split larger files into logical components
- **Use clear section headers** - Organize code with commented sections (e.g., `# Section name`)
- **Group related functions** - Keep functions that work together in the same file
- **Minimize cross-file dependencies** - Reduce coupling between modules

## Architecture

REPLicant is a socket-based Julia code evaluation server that allows remote execution of Julia code:

1. **Server Component** - Creates a socket server that listens on a dynamic port (starting from 8000), writes the port number to `REPLICANT_PORT` file, accepts code strings from clients, evaluates them, and returns results

2. **Revise Extension** (`ext/REPLicantReviseExt.jl`) - Provides automatic code reloading when Revise.jl is loaded, checks revision queue before executing code and runs `revise()` if needed

3. **Client Interface** (`justfile`) - Uses netcat (`nc`) to send code to the server, reads port from `REPLICANT_PORT` file to connect to the correct server instance

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
