"""
    REPLicant

A warm Julia REPL server. CLI tools and coding agents send code over a socket and
get REPL-style output back, without paying Julia startup on every call.

# Exports
- `Server`: socket server that evaluates code sent by clients

# Example
```julia
using REPLicant
server = REPLicant.Server()
# ... use the server ...
close(server)
```
"""
module REPLicant

#
# Imports.
#

import Dates
import Logging
import PrecompileTools
import Random
import Sockets

# `Base.ScopedValues` exists on 1.11+; vendor the slice the capture path needs on
# 1.10. Either path defines `ScopedValue`, `with`, and `getindex` in this module.
@static if isdefined(Base, :ScopedValues)
    import Base.ScopedValues: ScopedValue, with
else
    include("scopedvalues.jl")
end

include("server.jl")
include("registry.jl")
include("project.jl")
include("protocol.jl")
include("evaluation.jl")
include("client.jl")
include("channel.jl")
include("precompile.jl")

end # module REPLicant
