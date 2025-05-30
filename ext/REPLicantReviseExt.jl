module REPLicantReviseExt

import REPLicant
import Revise

# Override the base __revise function when Revise is available.
# This ensures that any code changes are automatically reloaded
# before executing client requests, matching typical REPL behavior.
function REPLicant.__revise(::Nothing, f, args...; kws...)
    if !isempty(Revise.revision_queue)
        # Force Revise to process all pending changes. We use throw=true
        # to ensure errors in revision are propagated rather than silently
        # ignored, which could lead to confusing behavior.
        Revise.revise(; throw = true)
    end

    # Use @invokelatest to ensure we call the newly loaded code.
    # This is critical because the function f might have been
    # redefined by the revision process.
    return @invokelatest f(args...; kws...)
end

end
