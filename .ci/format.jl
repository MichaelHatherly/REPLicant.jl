import Pkg
if Pkg.is_manifest_current(@__DIR__) !== true
    Pkg.update()
end

import JuliaFormatter
JuliaFormatter.format(dirname(@__DIR__))
