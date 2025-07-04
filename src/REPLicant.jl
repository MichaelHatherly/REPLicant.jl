"""
    REPLicant

A persistent Julia REPL server that enables fast code execution for CLI-based tools and coding agents.

# Exports
- `Server`: A socket server that evaluates Julia code sent by clients

# Example
```julia
using REPLicant
server = REPLicant.Server()  # Start the server
# ... use the server ...
close(server)  # Clean shutdown
```
"""
module REPLicant

#
# Imports
#

import IOCapture
import InteractiveUtils
import Printf
import Sockets

#
# Includes
#

include("filesystem.jl")
include("formatting.jl")
include("server.jl")
include("evaluation.jl")
include("metadata_helpers.jl")
include("metadata_commands.jl")
include("justfile_support.jl")

end # module REPLicant
