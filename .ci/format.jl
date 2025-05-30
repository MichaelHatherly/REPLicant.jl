import Pkg
Pkg.is_manifest_current(@__DIR__) || Pkg.update()

import JuliaFormatter
JuliaFormatter.format(dirname(@__DIR__))
