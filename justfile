# Set shell for all recipes
set shell := ["bash", "-c"]

default:
    just -l

# Execute Julia code through the running REPLicant server for this project.
# Pass name=LABEL to target a specific labeled server (see `REPLicant.label!`).
julia code name="":
    julia +rpc $([ -n "{{name}}" ] && echo "--name={{name}}") -e "{{code}}"

# List running REPLicant servers.
ls:
    julia +rpc ls

# Documentation lookup
docs binding:
    just julia "@doc {{binding}}"

# Run all tests. `--dir=test` anchors `@run_package_tests`'s scan root: from a
# `-e` request it resolves `..` against the evaluation directory, so without it
# the scan walks the parent of wherever the session happens to be rooted.
test-all:
    julia +rpc --dir=test -e "using TestItemRunner; @run_package_tests"

# Run tests filtered by space-separated tags
test-tag *tags:
    julia +rpc --dir=test -e 'using TestItemRunner; @run_package_tests filter=ti->issubset(Symbol.(split("{{tags}}")), ti.tags)'

# Run a single test item by name
test-item item:
    julia +rpc --dir=test -e 'using TestItemRunner; @run_package_tests filter=ti->ti.name == "{{item}}"'

# Run Dendro code-quality analysis over REPLicant's own source (separate Julia 1.12 environment)
dendro:
    julia +1.12 --project=test/dendro -e 'using Pkg; Pkg.instantiate()'
    julia +1.12 --project=test/dendro test/dendro/dendro.jl

changelog:
    julia --project=.ci .ci/changelog.jl

fmt:
    runic --inplace .

fmt-check:
    runic --check .
