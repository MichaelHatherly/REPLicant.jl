@testitem "eval_simple_arithmetic" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("2 + 2", 1, mod, "")
    @test !result.errored
    @test strip(result.output) == "4"
end

@testitem "eval_with_output" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    println("Hello")
    42
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    lines = split(strip(result.output), '\n')
    @test length(lines) == 2
    @test lines[1] == "Hello"
    @test lines[2] == "42"
end

@testitem "eval_trailing_semicolon_hides_value" tags = [:code_evaluation] begin
    # As at the REPL, a trailing `;` hides the value but not printed output. A `;`
    # inside a string or before a comment is not the end of the code.
    mod = Module()
    hidden = REPLicant._evaluate("println(\"shown\"); y = 1; # done", 1, mod, "")
    @test !hidden.errored
    @test strip(hidden.output) == "shown"
    @test mod.y == 1
    @test strip(REPLicant._evaluate("\"a;\"", 2, mod, "").output) == "\"a;\""
end

@testitem "eval_multiline_code" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    x = 10
    y = 20
    x + y
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test strip(result.output) == "30"
end

@testitem "eval_uses_repl_soft_scope" tags = [:code_evaluation] begin
    # As at the REPL, a top-level loop assigns the existing global.
    mod = Module()
    result = REPLicant._evaluate("x = 0; for i in 1:3; x += i; end; x", 1, mod, "")
    @test !result.errored
    @test strip(result.output) == "6"
end

@testitem "eval_function_definition" tags = [:code_evaluation] begin
    mod = Module()
    code = """
    function greet(name)
        "Hello, \$(name)!"
    end
    greet("World")
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test strip(result.output) == "\"Hello, World!\""
end

@testitem "eval_using_packages" tags = [:code_evaluation] begin
    mod = Module()
    # Test loading a standard library package
    code = """
    using Statistics
    mean([1, 2, 3, 4, 5])
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test strip(result.output) == "3.0"
end

@testitem "eval_empty_code" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("", 1, mod, "")
    @test !result.errored
    @test strip(result.output) == ""
end

@testitem "eval_nothing_result" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("nothing", 1, mod, "")
    @test strip(result.output) == ""
end

@testitem "eval_non_nothing_value_echoes" tags = [:code_evaluation] begin
    mod = Module()
    # Only `nothing` is suppressed; other falsy-looking values still echo.
    @test strip(REPLicant._evaluate("missing", 1, mod, "").output) == "missing"
    @test strip(REPLicant._evaluate("0", 1, mod, "").output) == "0"
    @test strip(REPLicant._evaluate("\"\"", 1, mod, "").output) == "\"\""
end

@testitem "eval_echo_rule_defined_in_same_eval" tags = [:code_evaluation] begin
    mod = Module()
    # Loading a package mid-eval adds its extension's echo rule in a newer world,
    # as the Test extension does for `DefaultTestSet`; the rule must still apply.
    code = """
    import REPLicant
    struct QuietValue end
    REPLicant._echo_object(::QuietValue) = false
    QuietValue()
    """
    @test strip(REPLicant._evaluate(code, 1, mod, "").output) == ""
end

@testitem "eval_array_display" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("[1, 2, 3]", 1, mod, "")
    @test contains(result.output, "3-element Vector{Int64}")
    @test contains(result.output, "1")
    @test contains(result.output, "2")
    @test contains(result.output, "3")
end

@testitem "eval_dict_display" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("Dict(:a => 1, :b => 2)", 1, mod, "")
    @test contains(result.output, "Dict{Symbol, Int64}")
    @test contains(result.output, ":a => 1") || contains(result.output, ":b => 2")
end

@testitem "eval_string_with_quotes" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("\"Hello \\\"World\\\"\"", 1, mod, "")
    @test strip(result.output) == "\"Hello \\\"World\\\"\""
end

@testitem "eval_display_output_is_captured" tags = [:code_evaluation] begin
    mod = Module()
    # `display(x)` writes through the display stack, not stdout; it must still be
    # captured alongside ordinary printed output.
    result = REPLicant._evaluate("display([1, 2, 3]); println(\"after\")", 1, mod, "")
    @test contains(result.output, "3-element Vector{Int64}")
    # Like the REPL's display, the shown value ends its line.
    @test contains(result.output, " 3\nafter")
end

@testitem "eval_display_is_limited" tags = [:code_evaluation] begin
    # As at the REPL, a displayed array is elided rather than printed in full.
    mod = Module()
    result = REPLicant._evaluate("display(collect(1:100_000)); nothing", 1, mod, "")
    @test contains(result.output, "⋮")
    @test countlines(IOBuffer(result.output)) < 100
end

@testitem "eval_display_captured_under_a_later_display" tags = [:code_evaluation] begin
    # The interactive REPL pushes its own display after the server installs
    # routing; an eval's `display` must still reach the capture, not that display.
    struct Grabber <: AbstractDisplay
        io::IOBuffer
    end
    Base.display(d::Grabber, M::MIME"text/plain", x) = show(d.io, M, x)
    Base.display(d::Grabber, x) = display(d, MIME"text/plain"(), x)

    REPLicant._install_routing!()
    grabber = Grabber(IOBuffer())
    pushdisplay(grabber)
    try
        result = REPLicant._evaluate("display([1, 2, 3])", 1, Module(), "")
        @test contains(result.output, "3-element Vector{Int64}")
        @test isempty(take!(grabber.io))
    finally
        popdisplay(grabber)
    end
end

@testitem "eval_child_given_stdout_is_captured" tags = [:code_evaluation] begin
    mod = Module()
    # Passing `stdout` hands the child the router's stream rather than fd 1; that
    # stream must be the capture while one is bound.
    code = "child = run(`echo handed`, devnull, stdout, stderr; wait = false); wait(child);"
    result = REPLicant._evaluate(code, 1, mod, "")
    @test contains(result.output, "handed")
end

@testitem "nested_capture_hands_fds_back_to_outer" tags = [:code_evaluation] begin
    # A test suite run inside a remote eval nests captures. When the inner one ends,
    # fd 1/2 must point at the outer capture again, not at the terminal.
    outer = REPLicant._capture() do
        REPLicant._capture(() -> nothing)
        run(`echo after-inner`)
        nothing
    end
    @test contains(outer.output, "after-inner")
end

@testitem "task_outliving_eval_writes_to_enclosing_capture" tags = [:code_evaluation] begin
    # A task inherits the eval's capture (1.11+) and may print after the eval ends,
    # when that capture is closed. Its output goes where the eval's own would go now.
    @static if VERSION >= v"1.11"
        mod = Module()
        outer = REPLicant._capture() do
            code = "t = @async (sleep(0.2); println(\"late\"); @info \"late log\"); nothing"
            REPLicant._evaluate(code, 1, mod, "")
            wait(Base.invokelatest(getproperty, mod, :t))
        end
        @test !outer.error
        @test contains(outer.output, "late")
        @test contains(outer.output, "late log")
    end
end

@testitem "router_redirect_stream_stays_real_during_capture" tags = [:code_evaluation] begin
    # `redirect_stdout(router)` makes `pipe_writer`'s stream the runtime's own
    # stdout, and a server closing mid-eval reinstalls routing inside a capture. Were
    # that the capture's file, runtime prints would go to a closed file for good.
    REPLicant._install_routing!()
    REPLicant._capture() do
        @test Base.pipe_writer(stdout) === REPLicant.REAL_OUT[]
    end
end

@testitem "eval_log_record_is_captured" tags = [:code_evaluation] begin
    mod = Module()
    result = REPLicant._evaluate("@info \"from the eval\"; 1 + 1", 1, mod, "")
    @test !result.errored
    @test contains(result.output, "Info: from the eval")
    @test endswith(strip(result.output), "2")
end

@testitem "eval_subprocess_output_is_captured" tags = [:code_evaluation] begin
    mod = Module()
    # `run(cmd)` inherits raw fd 1, bypassing the Julia `stdout` object. fd-level
    # capture must still funnel its output into the result.
    result = REPLicant._evaluate("run(`echo hello`)", 1, mod, "")
    @test contains(result.output, "hello")
end

@testitem "eval_c_library_output_is_captured" tags = [:code_evaluation] begin
    mod = Module()
    # A C library writing to fd 1 directly (here `puts`) bypasses Julia's streams;
    # fd-level capture catches it.
    result = REPLicant._evaluate("ccall(:puts, Cint, (Cstring,), \"viac\")", 1, mod, "")
    @test contains(result.output, "viac")
end

# Eval code defining `cwrite(fd, bytes)`, a raw C write to `fd`. The Windows CRT
# exports it as `_write`.
@testsnippet CWrite begin
    const CWRITE = """
    cwrite(fd, buf) = @static if Sys.iswindows()
        ccall(:_write, Cint, (Cint, Ptr{UInt8}, Cuint), fd, buf, length(buf))
    else
        ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, buf, length(buf))
    end
    """
end

@testitem "eval_c_write_past_pipe_buffer_is_captured" tags = [:code_evaluation] setup = [CWrite] begin
    mod = Module()
    # A pipe holds 64 KB; a C write larger than that must not be cut short.
    code = CWRITE * """
        cwrite(1, fill(UInt8('x'), 200_000))
        """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test count(==('x'), result.output) == 200_000
    @test endswith(strip(result.output), "200000")
end

@testitem "eval_subprocess_output_past_pipe_buffer_is_captured" tags = [:code_evaluation] begin
    mod = Module()
    code = raw"""
    run(`sh -c 'head -c 300000 /dev/zero | tr "\0" y; echo " rc=$?" >&2'`);
    """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test count(==('y'), result.output) == 300_000
    @test contains(result.output, " rc=0")
end

@testitem "killed_capture_leaves_no_file" tags = [:code_evaluation] begin
    # `kill --force` on a runaway eval skips every `finally`; the capture's file
    # must go with the process. `_exit` stands in for the kill.
    mktempdir() do tmp
        script = """
        import REPLicant
        REPLicant._capture() do
            print("doomed output")
            ccall(:_exit, Cvoid, (Cint,), 3)
        end
        """
        env = merge(ENV, Dict("TMPDIR" => tmp, "TMP" => tmp, "TEMP" => tmp))
        cmd = `$(Base.julia_cmd()) --project=$(pkgdir(REPLicant)) --startup-file=no -e $script`
        proc = run(setenv(ignorestatus(cmd), env))
        @test proc.exitcode == 3
        @test isempty(readdir(tmp))
    end
end

@testitem "eval_keeps_fds_blocking" tags = [:code_evaluation] begin
    mod = Module()
    # Children inherit fd 1/2 with their flags. Non-blocking, a child's write fails
    # with EAGAIN whenever the sink is momentarily full, and its output is lost.
    code = """
    F_GETFL = 3
    O_NONBLOCK = Sys.isapple() ? 0x0004 : 0x0800
    flags(fd) = @ccall fcntl(fd::Cint, F_GETFL::Cint)::Cint
    (flags(1) & O_NONBLOCK, flags(2) & O_NONBLOCK)
    """
    if Sys.iswindows()
        @test true skip = true
    else
        result = REPLicant._evaluate(code, 1, mod, "")
        @test strip(result.output) == "(0, 0)"
    end
end

@testitem "eval_large_c_write_interleaves_with_println" tags = [:code_evaluation] setup = [CWrite] begin
    mod = Module()
    code = CWRITE * """
        println("a")
        cwrite(1, fill(UInt8('x'), 100_000))
        println("\\nc");
        """
    result = REPLicant._evaluate(code, 1, mod, "")
    @test split(strip(result.output), '\n') == ["a", "x"^100_000, "c"]
end

@testitem "eval_subprocess_interleaves_with_println" tags = [:code_evaluation] begin
    mod = Module()
    # Julia-level writes and raw-fd subprocess writes share one pipe, so they land
    # in write order.
    result = REPLicant._evaluate("println(\"a\"); run(`echo b`); println(\"c\")", 1, mod, "")
    lines = split(strip(result.output), '\n')
    @test lines == ["a", "b", "c"]
end
