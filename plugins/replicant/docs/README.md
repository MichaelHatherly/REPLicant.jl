# REPLicant documentation

REPLicant keeps one Julia process warm as a socket server, and `julia +rpc`
forwards code to it.

## How-to guides

- [Install REPLicant](how-to/install.md)
- [Set up REPLicant for a coding agent](how-to/set-up-coding-agents.md)
- [Start, restart, and stop a server](how-to/manage-a-server.md)
- [Evaluate code on a server](how-to/evaluate-code.md)
- [Select a server when several are running](how-to/select-a-server.md)
- [Show server status at the bottom of the terminal](how-to/show-server-status.md)
- [Free a wedged server](how-to/free-a-wedged-server.md)

## Reference

The docstrings are the API reference: `?REPLicant.Server` at the REPL, and so on.
`julia +rpc help` lists every subcommand and flag.

- [Limits and concurrency](reference/limits.md)

## Explanation

- [How REPLicant works](explanation/how-it-works.md)
- [Security model](explanation/security.md)
