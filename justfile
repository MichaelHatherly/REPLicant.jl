# Set shell for all recipes
set shell := ["bash", "-c"]

default:
    just -l

julia code:
    printf '%s' "{{code}}" | nc localhost $(cat REPLICANT_PORT)

docs binding:
    just julia "@doc {{binding}}"

test-all:
    just julia "@run_package_tests"

test-tag *tags:
    just julia "#test-tags {{tags}}"

test-item item:
    just julia "#test-item {{item}}"

include-file file:
    just julia "#include-file {{file}}"

changelog:
    julia --project=.ci .ci/changelog.jl

format:
    julia --project=.ci .ci/format.jl
