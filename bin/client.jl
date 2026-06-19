# Client entrypoint for the juliaup `rpc` channel. `install_channel` links the
# channel to `julia --startup-file=no bin/client.jl`, so `julia +rpc <args>` runs
# this with the args appended. It runs in the default environment, which must have
# REPLicant available (dev or add it into the global env).
using REPLicant

exit(REPLicant.cli())
