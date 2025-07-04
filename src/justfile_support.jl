#
# Justfile setup and support
#

const JUSTFILE_RECIPES = """
# Execute Julia code via REPLicant
julia code:
    printf '%s' "{{code}}" | nc localhost \$(cat REPLICANT_PORT)

# Documentation lookup
docs binding:
    just julia "@doc {{binding}}"

# Run all tests
test-all:
    just julia "@run_package_tests"

# Run specific test item
test-item item:
    just julia "@run_package_tests filter=ti->ti.name == String(:{{item}})"
"""

"""
    justfile()

Create or update a justfile with REPLicant integration recipes.

This function helps set up a project to use REPLicant by creating or updating
a justfile with useful recipes for executing Julia code, looking up documentation,
and running tests.

# Behavior
- If no justfile exists: Creates a new `justfile` with REPLicant recipes
- If a justfile exists without a `julia` recipe: Appends REPLicant recipes  
- If a justfile exists with a `julia` recipe: Throws an error to avoid conflicts

# Supported justfile names
Searches for and updates any of these filenames (in order of preference):
- `justfile`
- `Justfile`
- `.justfile`
- `Justfile.just`
- `.justfile.just`

# Recipes added
- `julia code`: Execute Julia code through REPLicant
- `docs binding`: Look up documentation for a Julia binding
- `test-all`: Run all package tests using TestItemRunner
- `test-item item`: Run a specific test item by name

# Example
```julia
julia> using REPLicant

julia> REPLicant.justfile()
[ Info: Created justfile with REPLicant recipes
```

# Notes
- The function operates in the current working directory
- Recipes assume REPLicant server is running with a `REPLICANT_PORT` file
- The `julia` recipe uses `printf` and `nc` (netcat) for communication
"""
function justfile()
    # Find existing justfile
    existing = _find_just_file(pwd())

    if existing === nothing
        # Create new justfile
        path = joinpath(pwd(), "justfile")
        write(path, JUSTFILE_RECIPES)
        @info "Created justfile with REPLicant recipes" path
    else
        # Read existing content
        content = read(existing, String)

        # Check if julia recipe already exists
        if _contains_julia_recipe(content)
            error("Justfile already contains a 'julia' recipe at $existing")
        else
            # Append our recipes
            open(existing, "a") do io
                # Add newline if file doesn't end with one
                if !isempty(content) && !endswith(content, '\n')
                    println(io)
                end
                println(io, "\n# REPLicant recipes")
                print(io, JUSTFILE_RECIPES)
            end
            @info "Added REPLicant recipes to Justfile" existing
        end
    end
end

function _contains_julia_recipe(content::String)
    # Check if content contains a julia recipe definition
    # Recipe format: "recipe_name:" at start of line
    lines = split(content, '\n')

    for line in lines
        # Skip comments and empty lines
        stripped = strip(line)
        if startswith(stripped, "#") || isempty(stripped)
            continue
        end

        # Check for julia recipe (with optional parameters)
        if occursin(r"^julia\s*(\s+\w+)*\s*:", line)
            return true
        end
    end

    return false
end
