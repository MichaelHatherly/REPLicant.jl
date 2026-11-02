# How to set up REPLicant for a coding agent

REPLicant includes a skill for the Claude Code and Codex plugin systems. It
tells an agent how to install REPLicant and use `julia +rpc`.

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

The skill has the agent install REPLicant into the global environment, add the
startup.jl auto-start, link the `rpc` channel, and run a self-test (`julia +rpc ls` and `julia +rpc
-e '1 + 1'`).
