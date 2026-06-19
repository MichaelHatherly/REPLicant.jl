# REPLicant

Guidance for agents working on the REPLicant package itself.

## What it is for

Julia pays startup and compilation latency on every fresh process. Tools that run
many small evaluations (coding agents, CLI helpers, editor integrations) can't
afford that per call. REPLicant keeps one Julia process warm as a socket server,
and `julia +rpc <args>` forwards code to it. The session stays loaded, state
persists between calls, and the cold start is paid once.

Everything else follows from that: evaluation should be cheap, and REPLicant
should stay invisible to the project you are working on.

## Design values

Keep these when changing the package. They explain why the design looks the way it
does.

- **stdlib-only at runtime.** Runtime deps are `Dates`, `Logging`, `Random`,
  `Sockets`, plus `PrecompileTools`. The capture path was reimplemented to drop
  IOCapture rather than carry the dependency. A new runtime dep needs a strong
  reason. Optional integrations belong in extensions (Revise, Test as weakdeps).
- **One language.** Server and client are both Julia. No Go CLI, no launcher
  binary, no cross-compile release. juliaup's `link` with trailing args gives the
  `julia +rpc` UX for free. The cost is ~150-200ms of client boot per call; that
  trade is deliberate.
- **Simple over clever.** The registry is a directory of `key=value` files: no
  lock, no JSON, parseable by any client. The wire protocol is length-prefixed
  bytes read to EOF, so any socket client works without `nc`. Reach for machinery
  only when a real requirement forces it.
- **Out of the project's dependencies.** REPLicant lives in the global
  environment like Revise, never a direct dep of the project under work. The
  client runs with no `--project` and resolves `using REPLicant` from there.
- **Pay latency at build time.** `@compile_workload` precompiles the client and
  the server's socket handling, so first-call JIT cost lands at build time, not
  on the user.

## Architecture

Three parts. The code is the reference; this is the map:

- **Server** (`src/REPLicant.jl`): listens on a dynamic port, evaluates
  length-prefixed requests in a persistent module, registers itself in the shared
  registry directory.
- **Client** (`REPLicant.cli`, via `bin/client.jl`): reads the registry, resolves
  a target, forwards the request. The `rpc` juliaup channel runs it.
- **Registry**: one `key=value` file per live server, so any client finds every
  server in one place.

## Working in this repo

Commands live in the `justfile` (`just` with no args lists them): `just test-all`
and friends run the TestItemRunner suite, `just fmt` / `just fmt-check` run Runic.
Tests are `@testitem` blocks. Format with Runic before committing.
