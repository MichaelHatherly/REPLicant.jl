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
