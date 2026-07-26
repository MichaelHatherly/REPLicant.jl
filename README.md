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

## Use with coding agents (Claude Code / Codex)

REPLicant ships a skill through the Claude Code and Codex plugin systems. The
skill teaches an agent to install REPLicant and drive `julia +rpc`, so setup is a
single request rather than a checklist.

### Add the skill

Claude Code:

```
/plugin marketplace add MichaelHatherly/REPLicant
/plugin install replicant@replicant
```

Codex:

```
/plugin marketplace add MichaelHatherly/REPLicant
/plugin install replicant@replicant
/reload-plugins
```

### Install and verify

With the skill available, ask the agent:

> Install REPLicant and confirm `julia +rpc` works.

The skill installs into the global environment, links the `rpc` channel, wires
the startup.jl auto-start, and runs a self-test (`julia +rpc ls` and `julia +rpc
-e '1 + 1'`).

## Usage

### Start a server

A server stays alive as long as its Julia process. The usual setup is startup.jl:
open an interactive `julia` inside a project and it serves that project. To start
one by hand:

```julia
using REPLicant

REPLicant.Server()                 # quiet
REPLicant.Server(verbose = true)   # log lifecycle and per-connection events
```

`Server` keywords: `max_connections` (default 100), `read_timeout_seconds`
(default 30.0), `save` (default false, store the handle for `REPLicant.server()`),
`verbose` (default false, errors always log).

### Evaluate code

Use a heredoc with a quoted delimiter for anything beyond a trivial expression:

```bash
julia +rpc <<'EOF'
v = filter(isodd, 1:10)
sum(v)
EOF
```

One-liners can use `-e`:

```bash
julia +rpc -e '6 * 7'
julia +rpc -e 'println("hi"); 1 + 1'
```

Output is REPL-style: captured stdout and stderr first, then the value, or a
scrubbed error with backtrace.

### Session state

The server evaluates into a persistent `Main`, so bindings survive across calls:

```bash
julia +rpc -e 'x = [i^2 for i in 1:5]'   # define
julia +rpc -e 'sum(x)'                    # x is still in scope -> 55
```

`Main` is shared mutable state. Restart the server for a clean slate.

### Find and select servers

```bash
julia +rpc ls
```

Lists every live server: `PORT NAME PROJECT JULIA PID STARTED`. A server is
rooted at the project it started in (git top-level, else the working directory).
`julia +rpc` from inside that tree selects it, automatically when the project has
one server. Disambiguate with:

- `--name <label>`: pick a labeled server
- `--port <n>`: target a specific port
- `--project <path>`: select by project root (defaults to the current directory)

Label the current process's server, then route to it by name:

```bash
julia +rpc -e 'REPLicant.label!("main")'
julia +rpc --name=main -e '21 * 2'
```

Each label is unique among live servers for a project.

### Inspect a server

A server started with `save = true` (as the recommended startup.jl does) holds a
handle in its session:

```julia
REPLicant.server()        # the running Server, or nothing
close(REPLicant.server()) # stop it
```

Showing the handle reports port, project, name, start time, and limits.

### Pin status to the bottom of the terminal

```julia
REPLicant.footer!()
```

The bottom rows of the terminal show the server's status and the last few things
the session ran, from the prompt and over the socket alike:

```
#12 socket 14:03:21  using DataFrames
#13 repl 14:03:44  describe(df)
REPLicant  main  :8004  MyProject  up 12m  busy 3s
```

Those rows are taken out of the terminal's scrolling region rather than printed,
so the prompt keeps working and ordinary output scrolls underneath them.

The status row carries the server's label, port, project, and uptime, and whether
it is evaluating something right now, counting up for as long as it is. That last
field is what tells a long computation from a wedged one.

- `entries` sets how many activity rows to show: 3 by default, `0` for the status
  row alone. They are the same entries `julia +rpc log` renders in full.
- `footer!(false)` hands the rows back.

Ctrl-L clears the screen above the footer and leaves the footer alone. Call
`footer!()` from startup.jl alongside the server, or at the prompt at any time.
With output piped or redirected there is no terminal to draw on, and it returns
`false` without drawing.

### Stop a server

```julia
close(server)
```

This removes the server's registry entry. Exiting the Julia process stops the
server and cleans up the same way.

## How it works

1. The server lets the OS assign a free port and listens for
   length-prefixed requests.
2. It registers itself in a shared directory (`$REPLICANT_DIR`, else
   `tempdir()/replicant`), one `key=value` file per live server. The client reads
   that directory to find and select a target.
3. Code runs in a persistent module with `include_string`, so state survives
   between calls.
4. With Revise loaded, changed code reloads before each request.

## Risks and considerations

### Security

REPLicant executes arbitrary code with full system access.

- Only run it in trusted environments
- The server has no authentication or authorization
- Executed code has the same permissions as the Julia process

### Concurrency

- Each connection is handled in a separate task
- Concurrent requests share global state and can interfere
- `max_connections` (default 100) bounds concurrent connections
- At capacity, new connections receive `ERROR: Server at capacity, please retry`

## Development

### Running tests

```bash
just test-all
```

### Formatting

```bash
just fmt         # format in-place with Runic
just fmt-check   # check formatting (CI)
```
