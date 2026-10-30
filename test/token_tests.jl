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

@testitem "wrong_token_rejected_before_body_is_read" tags = [:protocol, :token] begin
    # A peer without the token must not get the server to buffer the body it
    # announces, up to 16MB per connection. The token is checked as it arrives.
    body = string(REPLicant._new_token(), repeat("x", 1024 * 1024))
    frame = IOBuffer()
    REPLicant._write_frame(frame, REPLicant.REQUEST_EVAL, body)
    read_wrong_token(io) =
    try
        REPLicant._read_request(seekstart(io), REPLicant._new_token(), 5.0)
    catch error
        error
    end
    read_wrong_token(frame)
    @test read_wrong_token(frame) isa REPLicant.Unauthorized
    @test @allocated(read_wrong_token(frame)) < 256 * 1024
end

@testitem "wrong_token_body_discard_has_one_deadline" tags = [:protocol, :token] begin
    import REPLicant
    import Sockets

    # A peer without the token that trickles its body a chunk at a time gets one
    # read timeout for the whole of it, not a fresh one per chunk.
    port, listener = Sockets.listenany(0)
    chunk = repeat("x", 64 * 1024)
    peer = @async begin
        sock = Sockets.connect(Sockets.localhost, port)
        write(sock, REPLicant.PROTOCOL_MAGIC, REPLicant.PROTOCOL_VERSION, REPLicant.REQUEST_EVAL)
        write(sock, hton(UInt32(REPLicant.TOKEN_LENGTH + 3 * ncodeunits(chunk))), REPLicant._new_token())
        for _ in 1:3
            write(sock, chunk)
            flush(sock)
            sleep(0.6)
        end
        close(sock)
    end
    sock = Sockets.accept(listener)
    err = try
        REPLicant._read_request(sock, REPLicant._new_token(), 1.0)
    catch error
        error
    end
    @test err isa REPLicant.ReadTimeout
    close(sock)
    close(listener)
    try
        wait(peer)
    catch  # dendro-ignore: empty_catch -- the peer's writes fail once the server closes
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
