# Client entrypoint for the juliaup `rpc` channel. `install_channel` links the
# channel to `julia --startup-file=no bin/client.jl`, so `julia +rpc <args>` runs
# this with the args appended. It runs in the default environment, which must have
# REPLicant available (dev or add it into the global env).
#
# `client-mode` sets the preference that selects REPLicant's client-only build. It is
# appended, so REPLicant still resolves from the environments ahead of it.
push!(LOAD_PATH, joinpath(@__DIR__, "client-mode"))
using REPLicant

exit(REPLicant.cli())
