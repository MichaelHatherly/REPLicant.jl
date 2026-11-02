# How to select a server when several are running

## List live servers

```bash
julia +rpc ls
```

Lists every registered server: `PORT NAME PROJECT JULIA PID STARTED STATUS`.
`STATUS` is `idle`, `busy` with the elapsed time, or `unresponsive` for a server
that is running but did not answer.

A server is rooted at the project it started in (git top-level, else the working
directory). `julia +rpc` from inside that tree selects it automatically when it
is the only server there. With nested projects, the deepest root containing the
current directory wins.

## Pick one

- `--name <label>`: pick a labeled server
- `--port <n>`: target a specific port
- `--project <path>`: select as if run from `<path>` (defaults to the current directory)

## Label a server

Label a server picked by port, then route to it by name:

```bash
julia +rpc --port=52417 -e 'REPLicant.label!("main")'
julia +rpc --name=main -e '21 * 2'
```

A label must be unique among the project's servers that answer a ping.
