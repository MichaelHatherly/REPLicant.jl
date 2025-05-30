@testmodule Utilities begin
    import Logging
    import REPLicant
    import Test

    # Sets up a temporary directory, creates a Justfile in it, required by the
    # socket server to detect the project directory.
    function withserver(
        func;
        max_connections::Int = 100,
        read_timeout_seconds::Float64 = 30.0,
    )
        mod = Module()
        mktempdir() do tmp
            justfile = joinpath(tmp, "justfile")
            open(justfile, "w") do f
                write(f, "default:\n    echo 'Justfile created for REPLicant server'\n")
                flush(f)
            end
            cd(tmp) do
                logger = Test.TestLogger()
                Logging.with_logger(logger) do
                    server = REPLicant.Server(mod; max_connections, read_timeout_seconds)
                    port = take!(server.channel)
                    @info "REPLicant server started" port max_connections
                    port_file = joinpath(tmp, "REPLICANT_PORT")
                    @assert isfile(port_file)
                    try
                        func(server, mod, port)
                    finally
                        close(server)
                    end
                end
            end
        end
    end
end
