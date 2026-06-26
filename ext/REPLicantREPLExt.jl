module REPLicantREPLExt

import REPLicant
import REPL

# Override the base __help fallback when REPL is available, rendering the full
# help mode: operators, keywords, macros, and apropos `?"text"` search.
function REPLicant.__help(::Nothing, query::AbstractString, mod::Module)
    return try
        io = IOBuffer()
        # helpmode prints a `search: ...` line to `io` and returns a docs object
        # (nothing for apropos `?"text"`, which prints its hits to `io`).
        docs = Core.eval(mod, REPL.helpmode(io, query, mod))
        (; output = String(take!(io)) * REPLicant._render_md(docs, mod), errored = false)
    catch error
        (; output = "ERROR: $(error)", errored = true)
    end
end

end
