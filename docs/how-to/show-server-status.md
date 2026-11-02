# How to show server status at the bottom of the terminal

Pin the status row, from the prompt or from startup.jl after the server starts:

```julia
REPLicant.footer!()
```

The bottom row of the terminal now shows the server, and while an evaluation
runs, how long it has run and the first line of its code:

```text
REPLicant  main  :52417  MyProject  up 12m  busy 3s  describe(df)
```

If the busy time climbs well past what the code should take, see
[Free a wedged server](free-a-wedged-server.md). Run `julia +rpc log` for recent
evals and their output.

Ctrl-L clears the screen above the row and leaves the row alone. Hand the row
back with:

```julia
REPLicant.footer!(false)
```

`?REPLicant.footer!` documents the function.
