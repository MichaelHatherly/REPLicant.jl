module REPLicantTestExt

import REPLicant
import Test

REPLicant._echo_object(::Test.DefaultTestSet) = false

REPLicant.PrecompileTools.@compile_workload REPLicant._run_workload()

end
