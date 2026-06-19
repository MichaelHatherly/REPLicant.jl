# Managing servers

Part of the `replicant` skill; see `SKILL.md`.

## Find and select servers

```bash
julia +rpc ls
```

Lists every live server: `PORT NAME PROJECT JULIA PID STARTED`. A server is rooted
at the project it started in (git top-level, else the working directory). `julia
+rpc` from inside that tree selects it. With one server for the project, selection
is automatic. Disambiguate with:

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
