@testitem "request_without_token_rejected" tags = [:protocol, :token] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        # A local peer that cannot read the registry has no token to send.
        sock = Sockets.connect(Sockets.localhost, port)
        body = REPLicant._encode_eval_body(; cwd = "", mod = "", code = "pwned = true")
        REPLicant._write_frame(sock, REPLicant.REQUEST_EVAL, body)
        frame = Utilities.readframe(sock)
        close(sock)
        @test frame.type == REPLicant.RESPONSE_ERR
        @test contains(frame.body, "token")
        @test !isdefined(mod, :pwned)
    end
end

@testitem "request_with_wrong_token_rejected" tags = [:protocol, :token] setup = [Utilities] begin
    import Sockets

    Utilities.withserver() do server, mod, port
        sock = Sockets.connect(Sockets.localhost, port)
        body = REPLicant._encode_eval_body(; cwd = "", mod = "", code = "pwned = true")
        REPLicant._write_request(sock, REPLicant._new_token(), REPLicant.REQUEST_EVAL, body)
        frame = Utilities.readframe(sock)
        close(sock)
        @test frame.type == REPLicant.RESPONSE_ERR
        @test contains(frame.body, "token")
        @test !isdefined(mod, :pwned)
    end
end

@testitem "ping_without_token_reads_as_dead" tags = [:protocol, :token] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        frame = Utilities.requestframe(port, REPLicant.REQUEST_PING, ""; token = "")
        @test frame.type == REPLicant.RESPONSE_ERR
        @test REPLicant._ping(port)
    end
end

@testitem "registry_entry_carries_token" tags = [:server_lifecycle, :token] setup = [Utilities] begin
    Utilities.withserver() do server, mod, port
        token = REPLicant._entry_token(port)
        @test length(token) == 64
        @test all(c -> c in "0123456789abcdef", token)
    end
end

@testitem "registry_dir_is_owner_only" tags = [:server_lifecycle, :token] begin
    import REPLicant

    # The entries carry tokens, so a registry other users can list is tightened.
    if !Sys.iswindows()
        mktempdir() do parent
            dir = joinpath(parent, "registry")
            mkdir(dir)
            chmod(dir, 0o755)
            withenv("REPLICANT_DIR" => dir) do
                REPLicant._registry_dir()
            end
            @test filemode(dir) & 0o777 == 0o700
        end
    end
end
