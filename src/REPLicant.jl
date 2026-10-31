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

# `bin/client.jl` loads a client-only build: `mode = "client"` set through the
# preferences of an environment it appends to `LOAD_PATH`. Julia caches that build
# apart from the full one, so a client call never loads the server's code or the
# packages only the server imports. The UUID is `Project.toml`'s, written out so the
# lookup also works where the module is not loaded as a package, as under JET.
const UUID = Base.UUID("8acbef56-6722-412a-9f59-5674813d37bb")
Base.record_compiletime_preference(UUID, "mode")
const CLIENT_ONLY = get(Base.get_preferences(UUID), "mode", "server") == "client"

import Base.JuliaSyntax
import Random
import Sockets

@static if !CLIENT_ONLY
    import Dates
    import Logging
    import PrecompileTools

    # `Base.ScopedValues` exists on 1.11+; vendor the slice the capture path needs on
    # 1.10. Either path defines `ScopedValue`, `with`, and `getindex` in this module.
    @static if isdefined(Base, :ScopedValues)
        import Base.ScopedValues: ScopedValue, with
    else
        include("scopedvalues.jl")
    end
end

@static if CLIENT_ONLY
    include("registry.jl")
    include("project.jl")
    include("protocol.jl")
    include("client.jl")
    include("channel.jl")
    include("workload.jl")
    include("precompile_client.jl")
else
    include("server.jl")
    include("restart.jl")
    include("registry.jl")
    include("project.jl")
    include("protocol.jl")
    include("evaluation.jl")
    include("activity.jl")
    include("footer.jl")
    include("status.jl")
    include("client.jl")
    include("channel.jl")
    include("workload.jl")
    include("precompile.jl")

    __init__() = (LAUNCH_DIR[] = pwd())
end

end # module REPLicant
