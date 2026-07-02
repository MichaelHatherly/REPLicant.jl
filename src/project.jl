#
# Project identity.
#

# Root the server at the enclosing git repository, falling back to the working
# directory. Clients select a server by matching this path (or an ancestor).
function _project_root(start::AbstractString = pwd())
    start = abspath(start)
    dir = start
    while true
        isdir(joinpath(dir, ".git")) && return _canonical(dir)
        parent = dirname(dir)
        parent == dir && return _canonical(start)
        dir = parent
    end
    return
end

# Resolve a path to its absolute, symlink-free form so the server and client
# compute the same identity for a directory (e.g. macOS /var -> /private/var).
# Falls back to a plain absolute path when the path cannot be resolved.
function _canonical(path::AbstractString)
    return try
        realpath(abspath(path))
    catch
        abspath(path)
    end
end

# Read the pinned `julia_version` from the Manifest.toml of the environment at
# `dir`. With `walk`, searches upward for the Project.toml that `--project=@.`
# would activate; without it, only `dir` itself is consulted (an explicit
# `--project` activates exactly the given path, no ancestor search). `nothing`
# when no project is found, or its manifest has never been resolved (no
# Manifest.toml yet, or a pre-`julia_version`-field manifest) -- nothing to
# compare against. Concrete `String`: this is `_check_julia_version`'s private
# helper, always called with its already-`String` `search_dir` local.
function _manifest_julia_version(dir::String, walk::Bool = true)
    probe = _canonical(dir)
    while true
        for project_name in ("JuliaProject.toml", "Project.toml")
            isfile(joinpath(probe, project_name)) || continue
            for manifest_name in ("JuliaManifest.toml", "Manifest.toml")
                manifest_file = joinpath(probe, manifest_name)
                isfile(manifest_file) || continue
                m = match(r"^julia_version\s*=\s*\"([^\"]+)\""m, read(manifest_file, String))
                isnothing(m) && return nothing
                capture = m.captures[1]
                return isnothing(capture) ? nothing : String(capture)
            end
            return nothing
        end
        walk || return nothing
        parent = dirname(probe)
        parent == probe && return nothing
        probe = parent
    end
    return
end
