# How to set up REPLicant for a coding agent

REPLicant includes a skill for the Claude Code and Codex plugin systems. It
tells an agent how to install REPLicant and use `julia +rpc`.

## Add the skill

Claude Code, at its prompt:

```
/plugin marketplace add MichaelHatherly/REPLicant.jl
/plugin install replicant@replicant
```

Codex, from a shell:

```bash
codex plugin marketplace add MichaelHatherly/REPLicant.jl
codex plugin add replicant@replicant
```

## Install and verify

With the skill available, ask the agent:

> Install REPLicant and confirm `julia +rpc` works.

The skill has the agent install REPLicant into the global environment, add the
startup.jl auto-start, link the `rpc` channel, and run a self-test (`julia +rpc ls`
and `julia +rpc -e '1 + 1'`).
