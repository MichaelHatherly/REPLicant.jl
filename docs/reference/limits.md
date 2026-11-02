# Limits and concurrency

## Evaluation

- Evals run one at a time. When `--timeout` expires, the eval keeps running on
  the server and later evals wait behind it. Free it with `julia +rpc interrupt`.
- `interrupt` is cooperative. Code that never yields, such as `while true; end`,
  ignores it. Sending the server SIGINT does not stop that code either, and can
  leave the server unable to answer requests. `julia +rpc restart` replaces the
  process and keeps its terminal. `julia +rpc kill --force` stops it outright.
  Either way the session state is lost.
- Julia 1.10 and 1.11 start without an interactive thread, so an eval can take the
  thread that answers requests. Code that never yields then blocks pings and
  `restart` too: `ls` shows the server as `unresponsive`, server selection skips
  it, and only `kill --force` stops it. Start the server's Julia with an
  interactive thread (`julia --threads=auto,1`) to keep it reachable. Julia 1.12
  and later start one by default.
- `exit()` in an eval stops the shared server. The client reports that the server
  exited.
- `restart` needs `execv`, so it works on macOS and Linux only.
- A client killed with SIGTERM prints Julia's signal report, such as
  `signal 15: Terminated: 15`, and the expression it was running. Julia's own
  signal handler prints it, as for any Julia process.

## Connections

- Each connection is handled in a separate task.
- Evals from different clients run one after another in the same session, so an
  eval sees whatever state earlier evals left behind.
- `ping`, `interrupt`, `reset`, `log`, and `restart` are answered while an eval
  runs.
- `max_connections` (default 100) bounds concurrent connections.
- At capacity, the client prints `Server at capacity, please retry` to stderr.
  Pings are still answered, so `ls` and server selection keep a full server.
