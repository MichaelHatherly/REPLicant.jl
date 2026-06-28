# REPLicant.jl changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Start a server from the client with `julia +rpc start`: it launches a detached process that outlives the client and prints the port once registered, so an agent with no interactive REPL can bring up a warm session. `--dir` roots it at a directory (default the caller's), `--project` picks the environment to activate, `--name` labels it, `--channel` runs a chosen juliaup channel (default the launcher's default version). The server loads `startup.jl` like a normal warm session. Stop it with `julia +rpc kill` [#41]
- Add named sessions with `--module <name>`: the eval runs in a standalone module instead of the shared default, isolating its state from `Main` and from other named sessions. State persists across calls under the same name, so a distinct name per task keeps `Main` clean [#41]
- Add `julia +rpc reset --module <name>` to swap a named session for a fresh, empty module, giving a clean slate without restarting the process. The default session is the process's `Main` and cannot be reset, so `--module` is required [#41]
- Run a script file with `julia +rpc path/to/script.jl [args...]`: a positional `.jl` argument is forwarded as an absolute path and run with `include`, so the script evaluates in the warm session with the real filename in stack traces, its definitions persisting like any other eval. Trailing positionals become the script's `ARGS` for the run, restored afterward so the session's `ARGS` is unchanged. A script file and `-e`/`--eval` are mutually exclusive [#40]
- Add `julia +rpc interrupt` to free a server wedged on a running eval without killing it: the request schedules an `InterruptException` onto the running evaluation, answered off the worker queue so it reaches a busy server, leaving the session and its loaded state intact. The worker runs each eval in its own task, so the interrupt frees that eval alone and the server keeps serving. Delivery is cooperative, so a tight non-yielding loop still needs `kill`; `interrupt` is the soft recovery tier [#39]
- Show evaluation state in `julia +rpc ls`: a `STATUS` column reads `idle`, or `busy <n>s` while the server is mid-evaluation, carried in the pong body so a wedged server is visible without a separate probe [#38]
- Add `julia +rpc kill [--force]` to terminate a server whose worker is wedged on a non-returning eval. The target resolves from the raw registry (no ping), so a server that cannot answer its socket still resolves; `kill` sends SIGTERM, `--force` sends SIGKILL, the only signal that lands on a tight non-yielding loop. Julia cannot interrupt a running task, so killing the process is the recovery [#38]
- Bound the client's wait for a result with `--timeout <seconds>`: an eval that does not respond in time frees the caller with a non-zero exit and a message pointing at `julia +rpc kill`, instead of stalling on a wedged server. Without the flag the client waits as long as the eval runs [#38]
- Capture subprocess and C-library output in rpc evals: a remote eval redirects fd 1/2 to its own pipe for its duration, so `run(cmd)` and C code writing directly to the file descriptors are returned to the client instead of leaking to the server's terminal [#36]
- Show remote evaluation in the interactive server's REPL: while a `julia +rpc` request runs, a single underscore sweeps through the prompt in every REPL mode and the terminal title shows a busy marker, reverting when it completes. Prompt colors are left at their defaults [#34][#37]
- Add a help mode: code beginning with `?` returns documentation, like the REPL. With REPL loaded (the interactive server) it is the full `helpmode`, covering operators, keywords, macros, and `?"text"` apropos search; a headless server falls back to `@doc` for bindings, operators, and macros. `??name` gives extended help [#33]
- Gate CI on a Dendro code-quality scan of the package source: a separate Julia 1.12 job fails the build on high-complexity bands or duplicate, stub, and swallowed-error flags [#28]

### Changed

- Run each eval in the caller's working directory: the client sends its directory with the request, so relative paths resolve where `julia +rpc` was invoked rather than where the server started, and a `cd` inside an eval no longer leaks to the next. Override with `--dir <path>` [#41]
- Warn on stderr when no server owns the caller's directory and a server from another project is used, so a cross-project eval is visible instead of silent. The call still runs [#41]
- Carry the working directory and target module in the eval frame, bumping the protocol version to 2. A client and server on mismatched versions read as incompatible and prompt to reinstall the rpc channel [#41]
- Point the `--timeout` expiry message at `julia +rpc interrupt` as the soft recovery before `kill` [#41]
- Route evaluation output per task instead of redirecting the process streams: a remote eval captures only its own output while the interactive server's REPL keeps writing to the terminal, so the two no longer steal each other's output [#36]
- Replace the length-prefixed wire protocol with a versioned binary frame protocol: a fixed header (magic, version, type code, body length) is validated on every message, and evaluation errors return a distinct frame type so the client routes them to stderr and exits non-zero [#32]
- Terminate client output with a newline so a result no longer runs into the shell prompt [#32]

### Fixed

- Stop discarding the result of an eval that runs longer than 30 seconds: the client read no longer applies the request timeout to the response, so a long compute returns instead of erroring [#38]
- Answer liveness pings off the worker queue and time the probe out quickly, so `ls` and server resolution stay responsive while a server is mid-evaluation instead of waiting on the request timeout [#35]
- Point protocol magic and version mismatch errors at reinstalling the rpc channel, since the usual cause is a client and server on different REPLicant versions [#35]
- Stop the client from crashing when its output pipe closes early (e.g. piping through `head`): the broken-pipe error is swallowed [#32]
- Capture `display(x)` output, which previously bypassed the result because it writes through the display stack rather than stdout [#32]
- Suppress the `nothing` echo: a `nothing` result now prints nothing, matching the REPL, so `display(x)` no longer leaves a trailing `nothing` [#33]

## [v2.0.0] - 2026-06-19

### Added

- Run servers behind a `julia +rpc` channel backed by a central registry: clients discover and route to running servers by project, with several labeled servers per project selectable via `--name` (`REPLicant.label!`) [#19]
- Add a `replicant` plugin so coding agents can install REPLicant and evaluate Julia through `julia +rpc` [#19]
- Add `save` and `verbose` keywords to `Server`, plus `REPLicant.server()` to recover a handle saved with `save = true` [#19]
- Run JET static analysis in the test suite: a `:basic` no-method guard on every supported Julia, plus a sound-mode and optimization-analyzer count ratchet pinned to Julia 1.12 [#21]

### Changed

- Replace the netcat client and `REPLICANT_PORT` file with a precompiled Julia client and a length-prefixed wire protocol [#19]
- Depend only on the standard library plus `PrecompileTools`, removing the IOCapture dependency [#19]
- Tighten types in the accept loop, `label!`, and the client-script path to drop the `Union{Nothing, ...}` and socket instabilities JET flagged [#21]

### Removed

- Remove the custom command syntax (`#test-item`, `#test-tags`, `#include-file`) [#19]

## [v1.1.1] - 2025-11-27

### Changed

- Server and worker tasks now use `errormonitor` to ensure errors are printed to stderr [#9]

## [v1.1.0] - 2025-06-07

### Added

- Added support for custom command syntax [#4]

## [v1.0.0] - 2025-05-31

Initial Public Release


<!-- Links generated by Changelog.jl -->

[v1.0.0]: https://github.com/MichaelHatherly/REPLicant.jl/releases/tag/v1.0.0
[v1.1.0]: https://github.com/MichaelHatherly/REPLicant.jl/releases/tag/v1.1.0
[v1.1.1]: https://github.com/MichaelHatherly/REPLicant.jl/releases/tag/v1.1.1
[v2.0.0]: https://github.com/MichaelHatherly/REPLicant.jl/releases/tag/v2.0.0
[#4]: https://github.com/MichaelHatherly/REPLicant.jl/issues/4
[#9]: https://github.com/MichaelHatherly/REPLicant.jl/issues/9
[#19]: https://github.com/MichaelHatherly/REPLicant.jl/issues/19
[#21]: https://github.com/MichaelHatherly/REPLicant.jl/issues/21
[#28]: https://github.com/MichaelHatherly/REPLicant.jl/issues/28
[#32]: https://github.com/MichaelHatherly/REPLicant.jl/issues/32
[#33]: https://github.com/MichaelHatherly/REPLicant.jl/issues/33
[#35]: https://github.com/MichaelHatherly/REPLicant.jl/issues/35
[#36]: https://github.com/MichaelHatherly/REPLicant.jl/issues/36
[#38]: https://github.com/MichaelHatherly/REPLicant.jl/issues/38
[#39]: https://github.com/MichaelHatherly/REPLicant.jl/issues/39
[#40]: https://github.com/MichaelHatherly/REPLicant.jl/issues/40
[#41]: https://github.com/MichaelHatherly/REPLicant.jl/issues/41
