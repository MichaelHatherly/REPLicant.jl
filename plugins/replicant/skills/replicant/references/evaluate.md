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

## Session state

The server evaluates into a persistent `Main`, so bindings survive across calls:

```bash
julia +rpc -e 'x = [i^2 for i in 1:5]'   # define
julia +rpc -e 'sum(x)'                    # x is still in scope -> 55
```

This is the point of a warm session, but `Main` is shared mutable state. Do not
assume a clean slate. Restart the server for a fresh session.
