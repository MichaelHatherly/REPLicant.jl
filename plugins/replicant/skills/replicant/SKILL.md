---
name: replicant
description: Evaluate Julia code in a warm REPLicant session with `julia +rpc`, instead of paying `julia` startup on every call. Use when running Julia snippets, checking a result, or exploring a package's API in a persistent session. For installing REPLicant, the `rpc` channel, or startup.jl, and for debugging why `julia +rpc` cannot reach a server, read references/setup.md.
---

# REPLicant

REPLicant keeps a Julia process alive as a socket server so code runs in a warm
session. `julia +rpc <args>` forwards code to the server for the current project
and prints the result, skipping the ~1s cold-start a fresh `julia` pays each call.

Prefer `julia +rpc` over `julia --project -e` for evaluating Julia from the shell.

The common case is a one-off evaluation:

```bash
julia +rpc <<'EOF'
v = filter(isodd, 1:10)
sum(v)
EOF
```

## Where to look

- **`references/evaluate.md`**: running code (heredoc vs `-e`, escaping inside
  wrappers, output format) and session state across calls.
- **`references/servers.md`**: listing servers with `julia +rpc ls`, selecting
  by `--name`/`--port`/`--project`, labeling with `label!`, inspecting a saved
  handle, and starting a server by hand.
- **`references/setup.md`**: when `julia +rpc` is not installed, is not a known
  channel, or cannot reach a server. Install, link the `rpc` channel, wire
  startup.jl, self-test, troubleshoot.

## Strategies

Getting the most from a warm session:

- **Front-load the cost, then iterate.** Load a heavy package or fixture once with
  `using` or `include`, then keep each eval small. The session holds what you
  loaded, so the compilation paid on the first call is free on every call after.
  Re-`using` a package in an eval only when you changed what you import.
- **Let Revise track your edits.** The recommended startup.jl loads Revise
  (`setup.md`), so editing a package's source updates the running session in
  place: change the code, re-run the call, read the new result. Restart only for a
  change Revise cannot track, such as redefining a `struct`, or a wedged worker.
- **Explore APIs live instead of guessing.** Evaluate an expression to see its real
  value and type, and use `?name` or `??name` for docs (`evaluate.md`). A warm
  session makes this cheap, so confirm a function's behavior rather than assuming
  it.
- **Isolate a task in its own module.** `--module <task>` keeps an experiment's
  bindings out of `Main` and out of other tasks; `reset --module <task>` clears it
  without restarting (`evaluate.md`). Reach for this when a scratch computation
  would otherwise clutter the default session.
- **Use it as a debugging feedback loop.** Define a reproduction once as a
  function, then vary its inputs across calls without paying startup each time. A
  fast, deterministic loop is what makes a bug tractable.
