# How to start, restart, and stop a server

A server stays alive as long as its Julia process.

## Start a server from startup.jl

Add this to `~/.julia/config/startup.jl`. Open an interactive `julia` inside a
project and it serves that project:

```julia
if isinteractive()
    try
        import REPLicant
        REPLicant.Server(save = true)
    catch error
        @error "Failed to start REPLicant server" error
    end
end
```

`save = true` keeps the handle, so `REPLicant.server()` returns it later.

## Start a server by hand

```julia
using REPLicant

REPLicant.Server()                 # quiet
REPLicant.Server(verbose = true)   # log lifecycle and per-connection events
```

`?REPLicant.Server` documents its keywords.

## Start a detached server

With no interactive REPL to host one, start a server from the shell:

```bash
julia +rpc start
```

It serves the current project. `julia +rpc help` lists the start options.

## Inspect a server

Show the saved handle to see its port, project, name, start time, and limits:

```julia
REPLicant.server()
```

## Restart a server

```bash
julia +rpc restart
```

The server re-execs its own Julia process on the argv it launched with. The pid,
terminal, environment, and launch directory stay the same. Everything loaded in
the session is dropped, and `startup.jl` runs again, so the server registers on a
new port. An interactive REPL comes back as a fresh REPL in the same terminal. It
runs the process's `atexit` hooks first, as `exit()` does. Restart needs `execv`,
so it works on macOS and Linux only.

## Stop a server

```julia
close(REPLicant.server())
```

This removes the server's registry entry. Exiting the Julia process stops the
server and cleans up the same way. From the shell, `julia +rpc kill` stops a
server.
