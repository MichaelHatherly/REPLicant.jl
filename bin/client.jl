# Client entrypoint for the juliaup `rpc` channel. `install_channel` links the
# channel to `julia --startup-file=no bin/client.jl`, so `julia +rpc <args>` runs
# this with the args appended. It runs in the default environment, which must have
# REPLicant available (dev or add it into the global env).
#
# `client-mode` sets the preference that selects REPLicant's client-only build. It is
# appended, so REPLicant still resolves from the environments ahead of it. Keep macros
# out of this file: expanding the first one, even `@__DIR__`, costs Julia 1.13 11ms.
push!(LOAD_PATH, joinpath(dirname(abspath(PROGRAM_FILE)), "client-mode"))
using REPLicant

exit(REPLicant.cli())
