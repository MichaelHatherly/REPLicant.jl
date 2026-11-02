# REPLicant.jl

```
██████╗ ███████╗██████╗ ██╗     ██╗ ██████╗ █████╗ ███╗   ██╗████████╗
██╔══██╗██╔════╝██╔══██╗██║     ██║██╔════╝██╔══██╗████╗  ██║╚══██╔══╝
██████╔╝█████╗  ██████╔╝██║     ██║██║     ███████║██╔██╗ ██║   ██║
██╔══██╗██╔══╝  ██╔═══╝ ██║     ██║██║     ██╔══██║██║╚██╗██║   ██║
██║  ██║███████╗██║     ███████╗██║╚██████╗██║  ██║██║ ╚████║   ██║
╚═╝  ╚═╝╚══════╝╚═╝     ╚══════╝╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝
```

Julia's startup and compilation latency makes a fresh process per snippet too
slow for tools that run many small evaluations. REPLicant keeps one Julia process
warm as a socket server and reuses it. `julia +rpc <args>` forwards code to the
server for the current project, prints the result, and pays the cold start once.
State survives between calls.

## Installation

Install REPLicant into the default (global) environment, like Revise. The `julia
+rpc` client runs with no `--project` and resolves `using REPLicant` from there:

```julia
using Pkg
Pkg.add("REPLicant")
```

Then link the `julia +rpc` channel once:

```julia
using REPLicant
REPLicant.install_channel()
```

To have a coding agent such as Claude Code or Codex set this up for you, see
[Set up REPLicant for a coding agent](docs/how-to/set-up-coding-agents.md).

## Quick use

Start a server from an interactive `julia` in your project:

```julia
using REPLicant
REPLicant.Server()
```

Then, from a shell in the same project:

```bash
julia +rpc -e '6 * 7'
```

[Start a server from startup.jl](docs/how-to/manage-a-server.md#start-a-server-from-startupjl)
so every interactive session serves its project.

## Documentation

See [docs/](docs/README.md). REPLicant runs any code sent to it with your
user's permissions; the [security model](docs/explanation/security.md) covers
who can send it code.
