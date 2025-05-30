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

test-tag tag:
    just julia "@run_package_tests filter=ti-> :{{tag}} in ti.tags"

test-item item:
    just julia "@run_package_tests filter=ti->ti.name == String(:{{item}})"

changelog:
    julia --project=.ci .ci/changelog.jl

format:
    julia --project=.ci .ci/format.jl
