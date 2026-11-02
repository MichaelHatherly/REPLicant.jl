# How to evaluate code on a server

## Send a block of code

Use a heredoc with a quoted delimiter for anything beyond a trivial expression:

```bash
julia +rpc <<'EOF'
v = filter(isodd, 1:10)
sum(v)
EOF
```

## Send a one-liner

```bash
julia +rpc -e '6 * 7'
julia +rpc -e 'println("hi"); 1 + 1'
```

Output is REPL-style: captured stdout and stderr first, then the value, or a
scrubbed error with backtrace.

## Build on earlier calls

The server evaluates into a persistent `Main`, so bindings survive across calls:

```bash
julia +rpc -e 'x = [i^2 for i in 1:5]'   # define
julia +rpc -e 'sum(x)'                    # x is still in scope -> 55
```

`Main` is shared mutable state. [Restart the server](manage-a-server.md#restart-a-server)
for a clean slate.

`julia +rpc help` lists the options for running a script, named sessions,
timeouts, and trimming long output.
