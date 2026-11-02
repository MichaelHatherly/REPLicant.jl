# How to select a server when several are running

## List live servers

```bash
julia +rpc ls
```

Lists every live server: `PORT NAME PROJECT JULIA PID STARTED`. A server is
rooted at the project it started in (git top-level, else the working directory).
`julia +rpc` from inside that tree selects it, automatically when the project has
one server.

## Pick one

- `--name <label>`: pick a labeled server
- `--port <n>`: target a specific port
- `--project <path>`: select by project root (defaults to the current directory)

## Label a server

Label the current process's server, then route to it by name:

```bash
julia +rpc -e 'REPLicant.label!("main")'
julia +rpc --name=main -e '21 * 2'
```

Each label is unique among live servers for a project.
