module REPLicantTestExt

import REPLicant
import Test

# The client-only build has none of the hooks this extends.
@static if !REPLicant.CLIENT_ONLY
    REPLicant._echo_object(::Test.DefaultTestSet) = false

    REPLicant.PrecompileTools.@compile_workload REPLicant._run_workload()
end

end
