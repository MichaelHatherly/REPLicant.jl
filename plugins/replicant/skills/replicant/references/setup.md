# REPLicant setup

Part of the `replicant` skill; see `SKILL.md`. Read this when REPLicant is not
installed, when `julia +rpc` is not a known channel, or when it cannot reach a
server.

## Install

REPLicant lives in the default (global) environment, like Revise, so it stays out
of the worked-on project's dependencies. The client runs with no `--project` and
resolves `using REPLicant` from there.

1. Install into the default env:

   ```bash
   julia -e 'using Pkg; Pkg.add("REPLicant")'
   ```

2. Auto-start a server in interactive REPLs. In `~/.julia/config/startup.jl`:

   ```julia
   if isinteractive()
       try
           import REPLicant
           REPLicant.Server(save = true)
       catch error
           @error "Failed to start REPLicant server" error
       end
   end
   ```

   Open an interactive `julia` inside a project and it serves that project.

   An agent with no interactive REPL starts one directly instead:

   ```bash
   julia +rpc start            # serve the current project, detached
   ```

   See `references/servers.md` for `start` flags and stopping a server.

3. Link the `rpc` juliaup channel once after installing:

   ```bash
   julia -e 'using REPLicant; REPLicant.install_channel()'
   ```

   Force a relink (e.g. after the channel points elsewhere) with
   `REPLicant.install_channel(force = true)`.

## Self-test

A server runs whenever an interactive `julia` is open in a project, so start one
(step 2 does this on REPL open), then from a separate shell:

```bash
julia +rpc ls            # lists the live server for this project
julia +rpc -e '1 + 1'    # prints 2
```

An empty `ls` means no server is running: open an interactive `julia` in the
project. A channel error means the link is missing: rerun step 3.

## Troubleshooting

- **`julia +rpc` reports no server / connection refused.** No server is running
  for this project. Run `julia +rpc start` (or open an interactive `julia`, which
  startup.jl serves). Confirm with `julia +rpc ls`.
- **`julia +rpc` is not a known channel, or runs the wrong target.** The channel
  is not linked, or points elsewhere. Link it (use `force = true` to overwrite a
  non-REPLicant target):

  ```bash
  julia -e 'using REPLicant; REPLicant.install_channel(force = true)'
  ```

- **`using REPLicant` fails inside the client.** REPLicant is not in the default
  env for the linked Julia version. Install it there under that version.
- **`ERROR: Server at capacity, please retry`.** All `max_connections` slots are
  busy. Retry, or start the server with a higher `max_connections`.
