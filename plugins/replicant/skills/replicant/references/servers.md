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
