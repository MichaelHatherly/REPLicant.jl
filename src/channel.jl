#
# juliaup channel self-install.
#

const RPC_CHANNEL = "rpc"

# The client script the `rpc` channel runs. Derives from the installed package
# dir, so it refreshes whenever a server re-installs the channel after a version
# bump. The client runs in the default environment (no `--project`) so REPLicant
# stays out of the worked-on project's dependencies, like Revise; it lives in the
# global env, where `using REPLicant` resolves for the client.
_client_script() = joinpath(pkgdir(@__MODULE__), "bin", "client.jl")
_julia_exe() = joinpath(Sys.BINDIR, Base.julia_exename())

_quiet(cmd::Cmd) = pipeline(cmd; stdout = devnull, stderr = devnull)
_has_juliaup() = success(_quiet(`juliaup --version`))

# juliaup.json lives in `$JULIAUP_DEPOT_PATH/juliaup` when that variable holds an
# absolute path, else `~/.julia/juliaup`. Mirrors juliaup's own resolution; it
# does not consult JULIA_DEPOT_PATH.
function _juliaup_config_path()
    depot = strip(get(ENV, "JULIAUP_DEPOT_PATH", ""))
    home =
        !isempty(depot) && isabspath(depot) ? joinpath(depot, "juliaup") :
        joinpath(homedir(), ".julia", "juliaup")
    return joinpath(home, "juliaup.json")
end

# Best-effort read of the `rpc` channel's entry in juliaup.json. Returns the raw
# JSON object text (a juliaup `link` channel is `{"Command": ..., "Args": [...]}`)
# or nothing when absent or unreadable. The brace match assumes the flat shape
# juliaup writes for linked channels; it does not handle nested objects.
function _linked_rpc_entry()
    path = _juliaup_config_path()
    isfile(path) || return nothing
    content = read(path, String)
    m = match(r"\"rpc\"\s*:\s*(\{[^}]*\})", content)
    return isnothing(m) ? nothing : m[1]
end

# Our linked entry names the client script under the REPLicant package dir, so
# the channel is ours when "replicant" appears anywhere in its definition.
_is_replicant_channel(entry::AbstractString) = occursin("replicant", lowercase(entry))

"""
    install_channel(; force = false)

Link the juliaup `rpc` channel to the REPLicant client script so `julia +rpc`
talks to a running server. Run once after installing REPLicant. No-op when juliaup
is unavailable. Refuses to overwrite a `rpc` channel pointing at a non-REPLicant
target unless `force`.
"""
function install_channel(; force::Bool = false)
    _has_juliaup() || return false

    current = _linked_rpc_entry()
    if !isnothing(current) && !_is_replicant_channel(current) && !force
        @warn "juliaup channel `$RPC_CHANNEL` points at a non-REPLicant target; not overwriting" current
        return false
    end

    julia = _julia_exe()
    script = _client_script()
    success(_quiet(`juliaup rm $RPC_CHANNEL`))  # ignore failure when absent
    # `--` stops juliaup parsing the trailing julia flags as its own options.
    # Quiet so linking at precompile time produces no output.
    run(_quiet(`juliaup link $RPC_CHANNEL $julia -- --startup-file=no $script`))
    @debug "Linked juliaup channel" channel = RPC_CHANNEL script
    return true
end
