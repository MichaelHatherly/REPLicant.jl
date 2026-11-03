# Managing servers

Part of the `replicant` skill; see `SKILL.md`.

## Find and select servers

[Select a server when several are running](../../../docs/how-to/select-a-server.md)
covers `julia +rpc ls`, the selectors, and labels. A `busy` status that keeps
climbing is a long compute or a wedge. Label a server you reach by `--port` so
later calls can route by `--name`.

## Start a server

`julia +rpc start` launches a server in a detached process that outlives the
client, then prints its port once it has registered:

```bash
julia +rpc start                       # serve the current directory's project
julia +rpc start --dir /path/to/proj   # serve another directory
julia +rpc start --project /env --name api   # pick the env, label it
julia +rpc start --channel 1.10        # run a different Julia version
```

`--dir` sets the working directory; the server is rooted at the enclosing project
(the git top-level of `--dir`, else `--dir` itself), which is how clients discover
it (default: the caller's directory). `--project` sets the Julia environment to
activate (default: the project of `--dir`). `--name` labels the server. Stop it
later with `julia +rpc kill`.

`--channel <name>` runs the server on a different juliaup channel (default: your
default channel). The channel must be installed (`juliaup add <name>`) and its global
environment must have REPLicant of a matching version, or the client reads the server
as a version-skew peer.

A `start`ed server loads your `startup.jl`, so Revise and other warm-session setup
apply. A one-off `julia +rpc` eval does not.

A server is pinned to one environment for its life. To work in a different
environment, `start` another server for it; the selection cascade routes each
`julia +rpc` call to the server owning its directory.

A git worktree roots as its own project, separate from the main checkout it
shares files with. A server in the main checkout does not serve its worktrees, so
`start` one per worktree; the cascade routes each call to its own and keeps their
sessions isolated. Claude Code's `.claude/worktrees/<name>` worktrees work this way.

## Reset a session

`julia +rpc reset --module <name>` swaps a named session for a fresh, empty module,
giving a clean slate without losing the warm process:

```bash
julia +rpc reset --module build
```

The default session is the process's `Main` and cannot be reset, so `--module` is
required. See `evaluate.md` for named sessions.

## Restart a server

[Start, restart, and stop a server](../../../docs/how-to/manage-a-server.md#restart-a-server)
describes what a restart keeps and drops. It takes the same selectors as eval:

```bash
julia +rpc restart --name=main
```

An interactive REPL comes back as a new REPL in the same pane, so the human beside
you keeps their terminal. The server comes up on a new port; route by `--name` or
directory, not a remembered `--port`. Everything the session loaded is gone, so
re-run your setup.

Reach for it when Revise cannot track a change (a redefined `struct`, a changed
`const`), when the process state is suspect, or when an eval has wedged the
worker. Restart is answered off the worker queue, so it lands even on a server
stuck in a tight loop. macOS and Linux only; on Windows, `kill` and `start`
instead.

## Stop a wedged server

A non-returning eval (`while true`, a deadlock, a blocking read) holds the worker.
`ls` then shows the server `busy`, and it never evaluates again. Prefer
`restart` (above), which keeps the process's terminal. Otherwise kill the process:

```bash
julia +rpc kill            # SIGTERM the resolved server, SIGKILL if it then cannot exit
julia +rpc kill --force    # SIGKILL, the only signal that lands on a tight loop
```

`kill` takes the same `--port`/`--name`/`--project` selectors as eval and resolves
from the registry without pinging, so a server that cannot answer still resolves.
Killing loses the session state; start a fresh server afterward.
