# How to install REPLicant

Install REPLicant into the default (global) environment, like Revise. The
`julia +rpc` client runs with no `--project` and resolves `using REPLicant` from
there:

```julia
using Pkg
Pkg.add("REPLicant")
```

Then link the `julia +rpc` channel once:

```julia
using REPLicant
REPLicant.install_channel()
```

To have every interactive `julia` serve its project, [start a server from
startup.jl](manage-a-server.md#start-a-server-from-startupjl). To have a coding
agent do this setup for you, see
[Set up REPLicant for a coding agent](set-up-coding-agents.md).
