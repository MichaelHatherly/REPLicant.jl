#
# File system utilities
#

function _find_just_file(dir::AbstractString = pwd())
    # Walk up the directory tree looking for a justfile.
    # Stop at git repository boundaries to avoid escaping the project.
    visited_dirs = Set{String}()

    choices = ("justfile", "Justfile", "JUSTFILE", ".justfile", ".Justfile", ".JUSTFILE")

    while true
        # Prevent infinite loops from symlinks or filesystem issues
        if dir in visited_dirs
            @warn "Circular directory structure detected while searching for justfile" dir
            return nothing
        end
        push!(visited_dirs, dir)

        for each in choices
            just_file = joinpath(dir, each)
            try
                if isfile(just_file)
                    return just_file
                end
            catch error
                # Log permission errors but continue searching upward.
                # If we can't read a directory, we likely can't read its parent either,
                # so we'll reach the root and exit gracefully.
                @debug "Error checking for justfile" dir error
            end
        end

        # Use .git as a boundary - don't search beyond the repository root
        try
            git_dir = joinpath(dir, ".git")
            if isdir(git_dir)
                return nothing
            end
        catch error
            # Permission error checking for .git, continue searching
            @debug "Error checking for .git directory" dir error
        end

        parent_dir = dirname(dir)
        if parent_dir == dir  # Reached filesystem root
            return nothing
        end
        dir = parent_dir
    end
end
