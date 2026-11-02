# How to start, restart, and stop a server

A server stays alive as long as its Julia process.

## Start a server from startup.jl

Add this to `~/.julia/config/startup.jl`. Each interactive `julia` then starts
a server rooted at the project it opened in:

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

srv = REPLicant.Server()                 # quiet
srv = REPLicant.Server(verbose = true)   # log lifecycle and per-connection events
```

`?REPLicant.Server` documents its keywords.

## Start a detached server

With no interactive REPL to host one, start a server from the shell:

```bash
julia +rpc start
```

It serves the current project. `julia +rpc help` lists the start options.

## Inspect a server

For a server started with `save = true`, show the saved handle to see its
port, project, name, start time, and limits:

```julia
REPLicant.server()
```

## Restart a server

```bash
julia +rpc restart
```

The server runs the process's `atexit` hooks, as `exit()` does, then re-execs
its Julia process on the argv it launched with. The pid, terminal, and
environment stay the same, and the process starts in the directory REPLicant was
loaded in. Everything loaded in the session is dropped. An interactive REPL comes
back as a fresh REPL in the same terminal.

The new process serves again only if its startup starts a server: through
`startup.jl`, or the launch command of `julia +rpc start`. It registers on a new
port. A server started by hand at the prompt does not come back, and the client
reports that it did not register again.

Restart needs `execv` and reads the argv from the OS, so it works on macOS and
Linux only.

## Stop a server

```julia
close(srv)
close(REPLicant.server())   # a server started with save = true
```

This removes the server's registry entry. Exiting the Julia process stops the
server and cleans up the same way. From the shell, `julia +rpc kill` stops a
server.
