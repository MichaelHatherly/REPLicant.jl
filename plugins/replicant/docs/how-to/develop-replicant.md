# How to run the tests and format the code

Run the test suite. It runs through `julia +rpc`, so start a server in this
repo first:

```bash
just test-all
```

Format with Runic, or check formatting as CI does:

```bash
just fmt
just fmt-check
```

`just` with no arguments lists the other commands.
