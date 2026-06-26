#
# Minimal `ScopedValue` for Julia 1.10.
#
# `Base.ScopedValues` ships in 1.11; REPLicant supports 1.10. This vendors the
# slice the capture path uses: construct a value, bind it for a dynamic extent
# with `with`, and read it with `[]`. Backed by `task_local_storage`, so the
# binding is same-task only. Child tasks the binding's body spawns do not inherit
# it, unlike the 1.11+ runtime feature. The capture path degrades accordingly:
# direct worker output is routed, output from tasks the eval spawns is not.

struct ScopedValue{T}
    default::T
end

# The value bound in the current task, or the default when unbound.
Base.getindex(var::ScopedValue) = get(task_local_storage(), var, var.default)::eltype(var)

Base.eltype(::ScopedValue{T}) where {T} = T

# Run `f` with `var` bound to `value` for the duration, restoring the prior
# binding (or its absence) on exit.
function with(f, (var, value)::Pair{<:ScopedValue})
    store = task_local_storage()
    had = haskey(store, var)
    old = had ? store[var] : nothing
    store[var] = value
    return try
        f()
    finally
        if had
            store[var] = old
        else
            delete!(store, var)
        end
    end
end
