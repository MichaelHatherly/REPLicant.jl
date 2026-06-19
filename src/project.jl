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
