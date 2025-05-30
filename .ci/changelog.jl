import Pkg
if Pkg.is_manifest_current(@__DIR__) !== true
    Pkg.update()
end

import Changelog
cd(dirname(@__DIR__)) do
    Changelog.generate(
        Changelog.CommonMark(),
        "CHANGELOG.md";
        repo = "MichaelHatherly/REPLicant.jl",
    )
end
