import Pkg
Pkg.is_manifest_current(@__DIR__) || Pkg.update()

import Changelog
cd(dirname(@__DIR__)) do
    Changelog.generate(
        Changelog.CommonMark(),
        "CHANGELOG.md";
        repo = "MichaelHatherly/REPLicant.jl",
    )
end
