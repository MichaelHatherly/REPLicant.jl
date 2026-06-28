@testitem "interrupt_frame_roundtrip" tags = [:protocol, :frame] begin
    import REPLicant

    buffer = IOBuffer()
    REPLicant._write_frame(buffer, REPLicant.REQUEST_INTERRUPT, "")
    seekstart(buffer)
    frame = REPLicant._read_frame(buffer, REPLicant.REQUEST_TYPES)
    @test frame.type == REPLicant.REQUEST_INTERRUPT
    @test frame.body == ""
    @test REPLicant.REQUEST_INTERRUPT in REPLicant.REQUEST_TYPES
end

@testitem "interrupt_frees_yielding_eval" tags = [:interrupt] setup = [Utilities] begin
    import REPLicant
    import Sockets

    Utilities.withserver() do server, mod, port
        # Seed session state so a follow-up eval proves the process survived.
        @test Utilities.request(port, "x = 41") == "41"

        # Wedge the worker on a non-returning but yielding eval. The connection is
        # held open without reading, so the worker stays busy on it.
        wedged = Sockets.connect(Sockets.localhost, port)
        Utilities.sendframe(wedged, "while true; sleep(0.01); end")
        sleep(0.5)  # let the worker pick it up and record current_eval

        # The interrupt is answered off the worker queue, so it lands even while
        # the worker is busy.
        frame = Utilities.requestframe(port, REPLicant.REQUEST_INTERRUPT, "")
        @test frame.type == REPLicant.RESPONSE_OK
        @test frame.body == "interrupted"

        # The freed eval reports the interrupt and closes.
        @test occursin("Interrupt", Utilities.readresp(wedged))
        close(wedged)

        # A follow-up eval on the same server sees prior state: the session lived.
        @test Utilities.request(port, "x + 1") == "42"
    end
end

@testitem "interrupt_idle_noop" tags = [:interrupt] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        frame = Utilities.requestframe(port, REPLicant.REQUEST_INTERRUPT, "")
        @test frame.type == REPLicant.RESPONSE_OK
        @test frame.body == "no evaluation running"
        # The server keeps evaluating afterward.
        @test Utilities.request(port, "1 + 1") == "2"
    end
end

@testitem "interrupt_cli_resolves_and_replies" tags = [:interrupt, :cli] setup = [Utilities] begin
    import REPLicant

    Utilities.withserver() do server, mod, port
        out = IOBuffer()
        @test REPLicant._interrupt_server(["--port=$port"]; out) == 0
        @test contains(String(take!(out)), "no evaluation running")
    end
end

@testitem "interrupt_does_not_kill_process" tags = [:interrupt, :kill] setup = [Utilities] begin
    import REPLicant
    import Sockets

    mktempdir() do work
        registry = mktempdir()
        withenv("REPLICANT_DIR" => registry) do
            Utilities.spawn_server(registry, work) do port, pid
                # Wedge the worker on a yielding non-returning eval, then wait until
                # the server reports busy so the interrupt lands on a running eval
                # rather than racing a worker that has not picked it up yet.
                wedged = Sockets.connect(Sockets.localhost, port)
                Utilities.sendframe(wedged, "while true; sleep(0.01); end")
                deadline = time() + 30
                while isempty(something(REPLicant._ping_status(port), "")) && time() < deadline
                    sleep(0.05)
                end

                out = IOBuffer()
                @test REPLicant._interrupt_server(["--port=$port"]; out) == 0
                @test contains(String(take!(out)), "interrupted")
                close(wedged)

                # The process survived the interrupt, unlike kill.
                @test REPLicant._process_alive(pid)
                @test Utilities.request(port, "1 + 2") == "3"
            end
        end
    end
end
