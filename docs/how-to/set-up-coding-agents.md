# How to set up REPLicant for a coding agent

REPLicant ships a skill through the Claude Code and Codex plugin systems. The
skill teaches an agent to install REPLicant and drive `julia +rpc`, so setup is a
single request.

## Add the skill

Claude Code:

```
/plugin marketplace add MichaelHatherly/REPLicant
/plugin install replicant@replicant
```

Codex:

```
/plugin marketplace add MichaelHatherly/REPLicant
/plugin install replicant@replicant
/reload-plugins
```

## Install and verify

With the skill available, ask the agent:

> Install REPLicant and confirm `julia +rpc` works.

The skill installs into the global environment, links the `rpc` channel, wires
the startup.jl auto-start, and runs a self-test (`julia +rpc ls` and `julia +rpc
-e '1 + 1'`).
