# Managing servers

Part of the `replicant` skill; see `SKILL.md`.

## Find and select servers

```bash
julia +rpc ls
```

Lists every live server: `PORT NAME PROJECT JULIA PID STARTED STATUS`. `STATUS` is
`idle`, or `busy <n>s` when the server is mid-evaluation (a long compute, or a
wedge). A server is rooted at the project it started in (git top-level, else the
working directory). `julia +rpc` from inside that tree selects it. With one server
for the project, selection is automatic. Disambiguate with:

- `--name <label>`: pick a labeled server (see below).
- `--port <n>`: target a specific port.
- `--project <path>`: select by project root (defaults to the current directory).

Label the current process's server, then route to it by name:

```bash
julia +rpc -e 'REPLicant.label!("main")'
julia +rpc --name=main -e '21 * 2'
```

Several servers can run in one project; each label is unique among live servers
there. An agent reaching a server by `--port` can label it the same way.

## Start a server

`julia +rpc start` launches a server in a detached process that outlives the
client, then prints its port once it has registered:

```bash
julia +rpc start                       # serve the current directory's project
julia +rpc start --dir /path/to/proj   # serve another directory
julia +rpc start --project /env --name api   # pick the env, label it
```

`--dir` sets the working directory; the server is rooted at the enclosing project
(the git top-level of `--dir`, else `--dir` itself), which is how clients discover
it (default: the caller's directory). `--project` sets the Julia environment to
activate (default: the project of `--dir`). `--name` labels the server. Stop it
later with `julia +rpc kill`.

A server is pinned to one environment for its life. To work in a different
environment, `start` another server for it; the selection cascade routes each
`julia +rpc` call to the server owning its directory.

## Reset a session

`julia +rpc reset --module <name>` swaps a named session for a fresh, empty module,
giving a clean slate without losing the warm process:

```bash
julia +rpc reset --module build
```

The default session is the process's `Main` and cannot be reset, so `--module` is
required. See `evaluate.md` for named sessions.

## Inspect a server

When a server was started with `save = true` (as the recommended startup.jl
does), the session holds a handle:

```julia
REPLicant.server()        # the running Server, or nothing
close(REPLicant.server()) # stop it
```

Showing the handle reports port, project, name, start time, and limits, read from
the struct, not the registry.

## Stop a wedged server

A server holding its worker on a non-returning eval (`while true`, a deadlock, a
blocking read) keeps `ls` showing it `busy` and never evaluates again. Julia
cannot interrupt a running task, so the recovery is to kill the process:

```bash
julia +rpc kill            # SIGTERM the resolved server
julia +rpc kill --force    # SIGKILL, the only signal that lands on a tight loop
```

`kill` takes the same `--port`/`--name`/`--project` selectors as eval and resolves
from the registry without pinging, so a server that cannot answer still resolves.
Killing loses the session state; start a fresh server afterward.

## Start a server by hand

When not relying on startup.jl:

```julia
using REPLicant
REPLicant.Server()                 # quiet
REPLicant.Server(verbose = true)   # log lifecycle and per-connection events
```

`Server` keywords: `max_connections` (default 100), `read_timeout_seconds`
(default 30.0), `save` (default false, store the handle for `server()`),
`verbose` (default false, errors always log).
