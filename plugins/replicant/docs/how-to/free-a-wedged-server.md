# How to free a wedged server

Evals run one at a time, so an eval that never finishes blocks every eval behind
it. A client `--timeout` does not stop it: the eval keeps running on the server.
Try these in order.

1. Interrupt the running eval. The session state survives.

   ```bash
   julia +rpc interrupt
   ```

   `interrupt` is cooperative. Code that never yields, such as `while true; end`,
   ignores it. Don't send the server SIGINT instead: the code keeps running, and
   the server can stop answering requests.

2. Restart the server. It keeps its pid and terminal and loses its session state.

   ```bash
   julia +rpc restart
   ```

   Restart works on macOS and Linux only. It needs the server to still answer requests. On Julia 1.10 and 1.11 it may
   not; see [Limits and concurrency](../reference/limits.md).

3. Kill it outright.

   ```bash
   julia +rpc kill --force
   ```
