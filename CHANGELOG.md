# REPLicant.jl changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- Restart a server in place with `julia +rpc restart`. Getting a fresh process used to mean killing the server, which takes an interactive REPL's terminal with it. The server now runs its `atexit` hooks, puts the terminal back in cooked mode, and calls `execv` on the argv it launched with, from the directory it launched in. The pid, terminal, and environment carry over, `startup.jl` runs again, and the server registers on a new port. The client waits for that entry before it reports the new port. The request is answered off the worker queue, so it also frees a server wedged in a loop that never yields. Restart needs `execv`, so it works on macOS and Linux only; Windows servers refuse it [#81]
- Require a per-server token on every request. A loopback port is reachable by any process on the machine, so another local user, or a sandboxed process allowed only localhost network, could run code as you through it. Each server now generates 32 random bytes at startup and writes them into its registry entry, and rejects any request whose body does not open with them, comparing in constant time. The registry moves to a per-user `tempdir()/replicant-<uid>` on Unix, forced to `0700`, and a directory owned by another user is refused, so only you can read the token or plant entries. The protocol version is now 3; clients and servers from earlier releases read as version-skewed [#57]
- Pin REPLicant's status to the bottom of the terminal with `REPLicant.footer!()`. A shared session gives the human at the prompt no view of the agent working alongside them: whether a server is even up, which one it is, and whether it is mid-evaluation or wedged. The footer answers all three in one row that updates on its own. While an evaluation runs, the row counts up its elapsed time and shows the first line of its code. The row is taken out of the terminal's scrolling region with DECSTBM rather than printed, so the prompt is never moved or redrawn and ordinary output scrolls underneath. Off by default; `footer!(false)` hands the row back. Ctrl-L is rebound to clear the screen above the footer, since erase-in-display ignores the scrolling region and would take the footer with it [#56]
- Elide chatty eval output with `julia +rpc --head-lines <n>` / `--tail-lines <n>`: a computation that dumps thousands of lines (an optimizer's per-iteration trace, a solver's progress) floods the agent's context with no ceiling. The flags bound the response client-side, keeping the first `n` and last `n` lines with a `…(N lines elided)` marker between. The response is stdout-first, value-last, so `--tail-lines` (or both) preserves the value or error; `--head-lines` alone keeps the start of a run. Off by default: with no flags the output is unchanged [#46]
- Record shared-session activity in a log the agent reads back with `julia +rpc log`. Each line typed at the interactive prompt and each eval sent over the socket is captured with its output into a bounded in-memory ring, so an agent joining a warm session sees what was run and its results without asking. Reads never drain the log: a positional count caps how many entries return, and `--since <id>` returns only those past a sequence cursor, so repeated catchup is incremental and safe to retry. Human input is captured by an AST transform on the REPL backend, human output by teeing the per-eval output router; a headless server with no interactive REPL records only its own evals [#46]
- Accept a zero-argument callable as `Server`'s default eval target, resolved per request. A host embedding a server can point it at a module it replaces over time, such as a notebook module swapped on re-init, without restarting the server [#46]
- Refuse `julia +rpc start --channel <ver>` when the target project's `Manifest.toml` is pinned to a different Julia minor version: starting anyway silently rebuilds the whole environment's precompile cache under the wrong version before the server can register, easily running past the registration timeout and looking like a hang rather than the version mismatch it is. Resolve the manifest under that channel or start on the channel that matches it. An explicit `--project` is checked exactly as given, with a relative path resolved against `--dir`; only the default `@.` searches parent directories for the project [#44]
- Print usage with `julia +rpc help` (also `--help` and `-h`), listing the subcommands, selectors, and per-mode flags so the surface is discoverable without the skill docs. An unrecognized argument now points at it [#42]
- Start a server from the client with `julia +rpc start`: it launches a detached process that outlives the client and prints the port once registered, so an agent with no interactive REPL can bring up a warm session. `--dir` roots it at a directory (default the caller's), `--project` picks the environment to activate, `--name` labels it, `--channel` runs a chosen juliaup channel (default the launcher's default version). The server loads `startup.jl` like a normal warm session. Stop it with `julia +rpc kill` [#41]
- Add named sessions with `--module <name>`: the eval runs in a standalone module instead of the shared default, isolating its state from `Main` and from other named sessions. State persists across calls under the same name, so a distinct name per task keeps `Main` clean [#41]
- Add `julia +rpc reset --module <name>` to swap a named session for a fresh, empty module, giving a clean slate without restarting the process. The default session is the process's `Main` and cannot be reset, so `--module` is required [#41]
- Run a script file with `julia +rpc path/to/script.jl [args...]`: a positional `.jl` argument is forwarded as an absolute path and run with `include`, so the script evaluates in the warm session with the real filename in stack traces, its definitions persisting like any other eval. Trailing positionals become the script's `ARGS` for the run, restored afterward so the session's `ARGS` is unchanged. A script file and `-e`/`--eval` are mutually exclusive [#40]
- Add `julia +rpc interrupt` to free a server wedged on a running eval without killing it: the request schedules an `InterruptException` onto the running evaluation, answered off the worker queue so it reaches a busy server, leaving the session and its loaded state intact. The worker runs each eval in its own task, so the interrupt frees that eval alone and the server keeps serving. Delivery is cooperative, so a tight non-yielding loop still needs `kill`; `interrupt` is the soft recovery tier [#39]
- Show evaluation state in `julia +rpc ls`: a `STATUS` column reads `idle`, or `busy <n>s` while the server is mid-evaluation, carried in the pong body so a wedged server is visible without a separate probe [#38]
- Add `julia +rpc kill [--force]` to terminate a server whose worker is wedged on a non-returning eval. The target resolves from the raw registry (no ping), so a server that cannot answer its socket still resolves; `kill` sends SIGTERM, `--force` sends SIGKILL, the only signal that lands on a tight non-yielding loop. Julia cannot interrupt a running task, so killing the process is the recovery [#38]
- Bound the client's wait for a result with `--timeout <seconds>`: an eval that does not respond in time frees the caller with a non-zero exit and a message pointing at `julia +rpc kill`, instead of stalling on a wedged server. Without the flag the client waits as long as the eval runs [#38]
- Capture subprocess and C-library output in rpc evals: a remote eval redirects fd 1/2 to its own pipe for its duration, so `run(cmd)` and C code writing directly to the file descriptors are returned to the client instead of leaking to the server's terminal [#36]
- Show remote evaluation in the interactive server's terminal title: while a `julia +rpc` request runs, the title shows a busy marker, reverting when it completes. The prompt itself is left alone; `REPLicant.footer!()` shows the same state with its elapsed time [#34][#37]
- Add a help mode: code beginning with `?` returns documentation, like the REPL. With REPL loaded (the interactive server) it is the full `helpmode`, covering operators, keywords, macros, and `?"text"` apropos search; a headless server falls back to `@doc` for bindings, operators, and macros. `??name` gives extended help [#33]
- Gate CI on a Dendro code-quality scan of the package source: a separate Julia 1.12 job fails the build on high-complexity bands or duplicate, stub, and swallowed-error flags [#28]

### Changed

- Cut a `julia +rpc` call from about 225ms to 165ms on Julia 1.11, against a floor of 110ms for starting Julia. The client used to load the whole package image, server code and all, and that image grew to 13MB once the precompile workload covered the server. It also loaded Dates, Logging, and PrecompileTools with its dependencies, none of which it uses. `bin/client.jl` now loads a client-only build of REPLicant, selected by a preference and cached apart from the full one, which loads no other package. On Julia 1.10 and 1.11 the client also stops compiling libuv's socket callbacks on every call, which the image left out before Julia 1.12. Julia builds the client-only image on its own after REPLicant changes, so a server started with `save = true` and `install_channel` both run `julia +rpc help` in the background to build it before a client call has to wait on it [#88]
- Compile what a server and client run on their first request into the package image. A server used to compile around 90 methods at runtime, mostly on its first eval, and the client recompiled its `_send` path for each combination of `--timeout`, `--head-lines`, and `--tail-lines`. The precompile workload now starts a real server and runs every client command against it, and the REPL, Revise, and Test extensions rerun it, since their methods invalidate the package code that calls the hooks they extend. The client wraps its output streams in one concrete type, so a terminal, a pipe, and a file share the same compiled code on every platform. A first eval now costs the same as later ones in a headless server and about 0.02s more with Revise, REPL, and Test loaded [#87]
- Keep a server process's running servers in one table. Exit cleanup and output routing each kept their own set under their own lock, so the two could drift apart. The activity log and the footer's repaint state move out of module globals into the `ActivityLog` and `Footer` structs. No behaviour change [#84]
- Reject `--module Main`: the default session is addressed by omitting `--module`, so a session named `Main` would be a distinct module shadowing that name. Eval and `reset` both error with that guidance instead of handing back a decoy [#42]
- Run each eval in the caller's working directory: the client sends its directory with the request, so relative paths resolve where `julia +rpc` was invoked rather than where the server started, and a `cd` inside an eval no longer leaks to the next. Override with `--dir <path>` [#41]
- Refuse to evaluate when no server owns the caller's directory and no explicit selector is given, listing the candidates instead of silently running against another project's server. Target a foreign server on purpose with `--port`, `--project`, or `--name` [#41][#42]
- Carry the working directory and target module in the eval frame, bumping the protocol version to 2. A client and server on mismatched versions read as incompatible and prompt to reinstall the rpc channel [#41]
- Point the `--timeout` expiry message at `julia +rpc interrupt` as the soft recovery before `kill` [#41]
- Route evaluation output per task instead of redirecting the process streams: a remote eval captures only its own output while the interactive server's REPL keeps writing to the terminal, so the two no longer steal each other's output [#36]
- Replace the length-prefixed wire protocol with a versioned binary frame protocol: a fixed header (magic, version, type code, body length) is validated on every message, and evaluation errors return a distinct frame type so the client routes them to stderr and exits non-zero [#32]
- Terminate client output with a newline so a result no longer runs into the shell prompt [#32]

### Fixed

- Stop `julia +rpc kill` from hanging a server it was meant to stop. `kill` sent SIGTERM, and Julia then ran the server's exit hooks from wherever its main thread happened to be. The hooks never finished inside a socket callback, such as the one handling the connection `kill` opens to check the server is up, so the process stayed up. `kill` now asks the server over its socket to shut down, and the server exits from a task of its own without printing a signal backtrace into its terminal. SIGTERM remains the fallback for a server too busy to answer [#87]
- Clear the copy of the footer a widening terminal leaves behind. Some terminals rejoin wrapped lines as they widen. The rejoining can lift the old footer into the blank rows below the prompt, and it stayed there as a second status row. The next repaint now erases from the cursor down. While the cursor is mid-edit the erase waits, so typed input is never lost [#85]
- Keep the prompt on screen when a terminal with the footer enabled loses height. The footer's row stopped the terminal trimming the blank rows below the prompt, so the prompt scrolled off the top and the screen stayed blank until the next keystroke. The REPL now redraws its prompt and input after the shrink [#85]
- Refuse a `--timeout` too large for the read timer, such as `inf`. It passed validation, so the client sent the eval and then failed with an `InexactError` while the eval kept running on the server [#83]
- Rewrite a registry entry in one step on macOS and Linux under Julia 1.10 and 1.11. There `mv(; force = true)` removes the old entry before renaming the new one, so a client reading during `label!` found no server, or no token and an `Unauthorized` reply [#83]
- Evaluate with the REPL's soft scope rules. `x = 0; for i in 1:3; x += i; end` threw `UndefVarError` over the socket while working at the prompt [#83]
- Keep the terminal when `julia +rpc restart` lands during a running eval. That eval held fd 1/2 on its capture file, and `execv` passed them to the new process, so the restarted REPL wrote into a deleted file [#83]
- Close a server without waiting out its running eval. `close(server)` waited for the eval and then ran every queued one, and the registry entry stayed until they all finished. Closing now interrupts the running eval, removes the entry, and answers queued requests with "Server shutting down" [#83]
- Keep the output of a task that outlives its eval. On Julia 1.11 and later a task spawned by an eval inherits its capture, and once the eval returned, the task's prints and log records went into the closed capture and were lost. They now go where the eval's own output would go at that moment: the enclosing capture, or the terminal [#83]
- Keep footer text inside its rows. A section error with a multi-line message, such as a `MethodError` listing its candidates, wrote a raw newline into the row below. A tab or carriage return in a section or in the running code moved the cursor too. Each footer row now draws control characters as spaces, and a section error shows its first line [#83]
- Leave the scrolling region alone once the footer is off. A repaint built before `footer!(false)`, an exit, or a restart could still be written after it, claiming the bottom rows again with nothing left to give them back [#83]
- Keep the footer off full-screen programs run from the prompt. The footer heard about a prompt eval before it ran, so within half a second it painted into `less`, `vim`, or `edit` on the alternate screen and set a scrolling region under them. Now the footer waits for the prompt's eval to return, then repaints. It also stays still during a long prompt eval; agent evals still update it [#83]
- Check a request's token before reading its body. The server read the whole body, up to 16 MB, before checking the token, including for every connection turned away at capacity. Any local process could make it hold that much per connection without knowing the token. A request without the token is now drained in 64 KB chunks and rejected [#83]
- Show the running code in a narrow footer once lower-priority fields make room. The code's share was measured before the project, uptime, or name were given up, so on a narrow terminal it vanished even when there was room after those went [#83]
- Leave the scrolling region at least two rows. With all but one row claimed, the footer sent a DECSTBM with its top equal to its bottom. Terminals ignore that, so the prompt scrolled over the footer [#83]
- Cap the code stored in the activity log, as its output already was. Each of the 200 entries kept its code in full, so a run of large scripts could hold gigabytes in memory and in a `log --since 0` reply [#83]
- Stop closed servers from leaving exit hooks behind. Each server added one, holding it and its sessions for the life of the process, and at exit it removed whatever registry entry then sat on its old port, possibly another process's live server. One hook now cleans up the servers still running [#83]
- Ignore a dead server's leftover entry when `julia +rpc kill` or `restart` picks a target. Next to a live server in the same project, the dead one made the choice ambiguous and the command asked for `--name` or `--port` [#83]
- Elide a large value passed to `display` in an eval, as the REPL does. `display(rand(10^6))` sent a million lines back to the client [#83]
- Keep an eval's output captured when a server in the same process closes. Routing is installed once per process and shared by every server in it, but each server tore it down on close. A test suite run as an eval in a warm session starts and closes servers of its own, so the rest of its output, and the fancy precompile spinner whose erase-to-end-of-screen wipes the footer, went to the human's terminal instead of back to the agent. The last running server now uninstalls routing, and a routing change inside a capture keeps fd 1/2 on that capture [#82]
- Capture eval output past 64 KB written to fd 1/2. The eval's output went through a pipe whose write end libuv keeps non-blocking, a flag the redirected fds and every child process share, so a C library or subprocess writing more than the pipe held got EAGAIN: a 200 KB C `write` stopped at 64 KB, and a subprocess could lose all of its output while `run` still reported success. The output now goes to a temporary file, which neither fails that way nor waits on a reader, and Julia, C and subprocess output stay in write order. The file has no name left to leave behind: Unix unlinks it at creation and Windows opens it delete-on-close, so a server force-killed in a runaway print loop leaves nothing in the temp directory [#80]
- Capture an agent's `display(x)` in a fresh interactive session. The REPL pushes its own display after startup.jl installs routing, so `display` printed in the human's terminal and the agent got nothing, until a server closed and reinstalled routing. The REPL's displayed results also skipped the activity log until then. A displayed value now ends its line, as at the REPL [#80]
- Report a value whose `show` throws the way the REPL does, as "Error showing value of type T:" followed by the error and the failing `show`'s frames. It came back as the exception's raw repr, `ERROR: ErrorException("boom")` [#80]
- Capture a child process handed `stdout` explicitly, as in `run(cmd, devnull, stdout, stderr; wait = false)`. It wrote to the real terminal instead [#80]
- Keep fd 1/2 on the enclosing capture when a nested one ends, as when a test suite runs inside a remote eval. C and subprocess output after the inner eval reached the terminal [#80]
- Show the terminal title's busy marker and animate the footer only while the session's own server evaluates. Test servers evaluating in the same process marked it busy too [#80]
- Keep `REPLicant.label!`, `REPLicant.server()` and the footer on the session's own server. Every `Server` constructor overwrote the process's current server, so after a warm test run `label!("main")` labeled a closed test server or failed, and `server()` returned `nothing`. An unsaved server no longer displaces a running `save = true` server, so the session's own server stays put. Add `label!(server, name)` to label a server by its handle [#79]
- Hide the value of an eval whose code ends in `;`, as the REPL does. `julia +rpc -e 'y = 1;'` printed `1`. Printed output still comes through, and a `;` inside a string or followed by a comment is read the way the REPL reads it [#76]
- Keep the footer on the server it was enabled for. It read the process's current server, which every `Server` constructor overwrites, so running the test suite in a warm session showed each test's server in the row and then "no server" once that server closed [#75]
- Refuse a `--dir` that does not exist with "no such directory: <path>". The eval failed inside `cd`, and the client printed the raw `Base.IOError(...)` repr while the server logged it as an evaluation error [#74]
- Refuse `reset --module <name>` for a session no eval has created, and refuse a `--module` name that is not a Julia identifier. A typo in a reset printed "reset module ..." and created an empty session, and `--module 'bad name!'` made a module no code can name [#73]
- Stop logging `Error handling client` into the REPL for a request the caller got wrong, such as `reset --module Main`, or for a client that hung up before its result. The caller already gets the rejection, and a client whose `--timeout` expired is routine. Its hang-up also printed a second `@error` when the error reply failed on the closed socket [#72]
- Report a server that exits during an eval. `exit()` in an eval stops the shared server, and the client said only "server closed the connection without a response". When the dropped connection's port now refuses, the client says the server exited and that `exit` in an eval is the usual cause [#71]
- Warn in the `--timeout` expiry message that later evals queue behind the one still running. The worker is sequential, so the next call waits until the timed-out eval finishes or is interrupted, and nothing told the caller why it stalled [#70]
- Precompile the client for the streams it runs on. The workload only reached `cli` with IOBuffer streams, so a client whose stdout or stderr was a pipe or a file, as every agent call is, compiled `cli` and `_send` at runtime. That took a `julia +rpc -e '1 + 1'` from about 0.2s to 0.7s, slower than a cold `julia` [#69]
- Stop logging errors into the REPL for a peer that stalls past the read timeout. The timeout closes the socket, so the server's error reply always failed, and each stalled connection printed two `@error` records at the human's prompt [#67]
- Count lines correctly in `--head-lines` and `--tail-lines` when the output ends in a newline. The empty string after the final newline counted as a line, so `--tail-lines=2` kept only one line of printed output and `--head-lines` reported an elision that removed nothing [#66]
- Remove only REPLicant's own display when a server shuts down. With the server started from `startup.jl`, the REPL pushes its display afterwards, and closing the server popped the REPL's display while leaving REPLicant's behind [#65]
- Define `eval` in named sessions. A `--module` session wired up only `include`, so `eval(expr)` inside it failed with `UndefVarError` where a `module ... end` block would evaluate into itself [#64]
- Make `close(server)` a no-op on a server that has already stopped. A second call threw "schedule: Task not runnable" [#63]
- Report a server that survives `julia +rpc kill` instead of claiming it terminated. `kill` dropped the registry entry right after sending SIGTERM, so a server that kept running could no longer be found by `kill --force`. It now waits for the process to exit, and otherwise keeps the entry and exits non-zero with a pointer to `--force`. `julia +rpc interrupt` likewise exits non-zero and writes to stderr when the server answers with an error such as "Server at capacity" [#62]
- Install the REPL hooks when REPL loads after REPLicant. On Julia 1.11+ REPL loads only after `startup.jl` has started the server and enabled the footer. `julia +rpc log` then never recorded what the human typed, and Ctrl-L kept wiping the footer [#61]
- Accept eval output over 16 MB in the client. The client capped responses at the server's request limit, so a large output failed with "Frame too large" after the eval had already run and its output was lost [#60]
- Report a failed Revise revision to the client as an error. The revision ran before the eval's error handling. When a tracked file failed to re-evaluate, nothing answered the request or closed its socket, and `julia +rpc` without `--timeout` hung until killed [#59]
- Keep the registry entry of a server too busy to answer a ping. A server running a non-yielding eval on its only thread misses the 2s pong, and any `ls`, eval, or new server start deleted its entry for good, leaving it unreachable by `ls`, `interrupt`, and `kill`. An entry is now pruned only when its port refuses connections or its process has exited, and `ls` lists the busy server as `unresponsive`. `kill` applies the same check before signalling, so an entry left by a crashed server no longer sends SIGTERM to an unrelated process that reused its pid. Registry readers also skip the temporary files of an in-flight write and entries removed between listing and reading, which previously showed up as duplicate servers or crashed the client [#58]
- Bind the server to an OS-assigned ephemeral port instead of scanning up from 8000. Port 8000 is a common dev-server default. When that dev server was down, REPLicant took its port and logged an error for every HTTP health check aimed at it. A peer that doesn't speak the REPLicant protocol still gets an error reply, but the server now logs it at debug level [#55]
- Root a server started in a git worktree at the worktree itself, not the checkout that encloses it. A worktree's `.git` is a file, not a directory, so the old directory-only check walked past it to the enclosing repository: every worktree nested under a checkout (Claude Code's default `.claude/worktrees/<name>`) took on the main project's identity and collided with it in the registry. Servers in separate worktrees now stay isolated [#45]
- Scrub REPLicant's own eval frames from the backtrace of an error raised before any user frame (an undefined top-level binding), which previously dumped the server's internal machinery to the caller. The backtrace now matches the REPL [#42]
- Report `julia +rpc interrupt` honestly: after scheduling the interrupt, the client confirms the server returned to idle before claiming success, and points at `kill --force` when a non-yielding eval keeps running, instead of always reporting `interrupted` [#42]
- Give a clear error when `--port` targets a port with no live server, instead of leaking a raw connection-refused `IOError` [#42]
- Quiet the `Labeled REPLicant server` log unless the server is started verbose [#42]
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
[#42]: https://github.com/MichaelHatherly/REPLicant.jl/issues/42
[#44]: https://github.com/MichaelHatherly/REPLicant.jl/issues/44
[#45]: https://github.com/MichaelHatherly/REPLicant.jl/issues/45
[#46]: https://github.com/MichaelHatherly/REPLicant.jl/issues/46
[#55]: https://github.com/MichaelHatherly/REPLicant.jl/issues/55
[#56]: https://github.com/MichaelHatherly/REPLicant.jl/issues/56
[#57]: https://github.com/MichaelHatherly/REPLicant.jl/issues/57
[#58]: https://github.com/MichaelHatherly/REPLicant.jl/issues/58
[#59]: https://github.com/MichaelHatherly/REPLicant.jl/issues/59
[#60]: https://github.com/MichaelHatherly/REPLicant.jl/issues/60
[#61]: https://github.com/MichaelHatherly/REPLicant.jl/issues/61
[#62]: https://github.com/MichaelHatherly/REPLicant.jl/issues/62
[#63]: https://github.com/MichaelHatherly/REPLicant.jl/issues/63
[#64]: https://github.com/MichaelHatherly/REPLicant.jl/issues/64
[#65]: https://github.com/MichaelHatherly/REPLicant.jl/issues/65
[#66]: https://github.com/MichaelHatherly/REPLicant.jl/issues/66
[#67]: https://github.com/MichaelHatherly/REPLicant.jl/issues/67
[#69]: https://github.com/MichaelHatherly/REPLicant.jl/issues/69
[#70]: https://github.com/MichaelHatherly/REPLicant.jl/issues/70
[#71]: https://github.com/MichaelHatherly/REPLicant.jl/issues/71
[#72]: https://github.com/MichaelHatherly/REPLicant.jl/issues/72
[#73]: https://github.com/MichaelHatherly/REPLicant.jl/issues/73
[#74]: https://github.com/MichaelHatherly/REPLicant.jl/issues/74
[#75]: https://github.com/MichaelHatherly/REPLicant.jl/issues/75
[#76]: https://github.com/MichaelHatherly/REPLicant.jl/issues/76
[#79]: https://github.com/MichaelHatherly/REPLicant.jl/issues/79
[#80]: https://github.com/MichaelHatherly/REPLicant.jl/issues/80
[#81]: https://github.com/MichaelHatherly/REPLicant.jl/issues/81
[#82]: https://github.com/MichaelHatherly/REPLicant.jl/issues/82
[#83]: https://github.com/MichaelHatherly/REPLicant.jl/issues/83
[#84]: https://github.com/MichaelHatherly/REPLicant.jl/issues/84
[#85]: https://github.com/MichaelHatherly/REPLicant.jl/issues/85
[#87]: https://github.com/MichaelHatherly/REPLicant.jl/issues/87
[#88]: https://github.com/MichaelHatherly/REPLicant.jl/issues/88
