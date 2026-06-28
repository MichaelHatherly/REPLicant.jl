# Evaluating code

Part of the `replicant` skill; see `SKILL.md`.

## Run code

Use a heredoc with a quoted delimiter for anything beyond a trivial expression.
The quoted `'EOF'` keeps the shell from touching the code, so `$`, `!`, and quotes
reach Julia intact:

```bash
julia +rpc <<'EOF'
v = filter(isodd, 1:10)
sum(v)
EOF
```

One-liners can use `-e`. Inside single quotes the inner double quotes are literal,
so do not escape them:

```bash
julia +rpc -e '6 * 7'
julia +rpc -e 'println("hi"); 1 + 1'
```

A wrapper that passes the code through a second shell layer (a Make target, a task
runner) needs the inner double quotes escaped as `\"`. Reaching for a heredoc
avoids the question.

Output is REPL-style: captured stdout and stderr first, then the value, or a
scrubbed error with backtrace.

## Working directory

The eval runs in the directory where you invoked `julia +rpc`, not where the
server started, so relative paths resolve against your shell's location:

```bash
cd src
julia +rpc -e 'isfile("REPLicant.jl")'   # true: resolved against src/
```

Override the directory with `--dir`:

```bash
julia +rpc --dir /path/to/project -e 'readdir()'
```

A `cd` inside an eval does not leak: the next call runs in the caller's directory
again.

The directory is set on the server process for the eval's duration (Julia has one
working directory per process, not per task). The worker is sequential, so evals
never see each other's directory, but a person sharing the same server through its
interactive REPL sees the eval's directory while it runs. A server started with
`julia +rpc start` is headless, so this only applies to a server shared with a live
REPL.

## Bounding the wait

By default the client waits as long as the eval runs, so a deliberate long compute
returns its result. To cap the wait, pass `--timeout <seconds>`:

```bash
julia +rpc --timeout 10 -e 'long_running()'
```

On expiry the client exits non-zero and prints a message pointing at `julia +rpc
interrupt` (or `kill`). The eval keeps running on the server; the timeout only
frees the caller. See `servers.md` for recovering a wedged server.

## Help mode

A leading `?` returns documentation, like the REPL's help mode. Use `?name` for
brief help, `??name` for extended:

```bash
julia +rpc -e '?println'
julia +rpc -e '?+'
```

With REPL loaded (the interactive server, the default) this is the full help mode:
operators, keywords, macros, and `?"text"` apropos search. A headless server falls
back to `@doc`, covering bindings, operators, and macros.

## Session state

The server evaluates into a persistent `Main`, so bindings survive across calls:

```bash
julia +rpc -e 'x = [i^2 for i in 1:5]'   # define
julia +rpc -e 'sum(x)'                    # x is still in scope -> 55
```

This is the point of a warm session, but `Main` is shared mutable state. Do not
assume a clean slate. Restart the server for a fresh session.

## Named sessions

`--module <name>` evaluates into a separate session, isolating its state from
`Main` and from other named sessions. Use a distinct name per task to avoid
polluting the default session:

```bash
julia +rpc --module build -e 'cfg = load_config()'   # define in `build`
julia +rpc --module build -e 'run(cfg)'              # cfg still in scope
julia +rpc -e 'cfg'                                  # UndefVarError: Main has no cfg
```

Clear a named session without restarting the server:

```bash
julia +rpc reset --module build
```

`Main` cannot be reset (it is the process default), so `reset` requires
`--module`.

Each named session lives for the server's lifetime; `reset` empties one but keeps
the name. Reusing a small set of names keeps memory flat. A server handed a fresh
name on every call accumulates modules, so restart it (or reuse names) to reclaim
that memory.
