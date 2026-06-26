#
# Output capture.
#

# Run `f` with stdout, stderr, and logging redirected to a pipe, returning the
# captured text alongside the value (or the thrown exception and its backtrace).
# InterruptException is rethrown so long-running code stays interruptible.
function _capture(f)
    default_stdout = stdout
    default_stderr = stderr

    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    redirect_stdout(pipe.in)
    redirect_stderr(pipe.in)
    # `display(x)` writes through the display stack, not the redirected stdout, so
    # push a text display onto the pipe to capture it too.
    pushdisplay(Base.Multimedia.TextDisplay(pipe.in))
    logger = Logging.ConsoleLogger(pipe.in)

    # Spawning the reader task draws from the task RNG; copy and restore it so
    # user code sees an unperturbed random stream.
    old_rng = copy(Random.default_rng())
    capture_buffer = IOBuffer()
    reader = @async write(capture_buffer, pipe)
    copy!(Random.default_rng(), old_rng)

    value, errored, backtrace = Logging.with_logger(logger) do
        try
            yield()
            f(), false, Vector{Ptr{Cvoid}}()
        catch err
            err isa InterruptException && rethrow()
            err, true, catch_backtrace()
        finally
            redirect_stdout(default_stdout)
            redirect_stderr(default_stderr)
            popdisplay()
            close(pipe.in)
            wait(reader)
        end
    end

    return (
        output = String(take!(capture_buffer)),
        value = value,
        error = errored,
        backtrace = backtrace,
    )
end

#
# Code evaluation.
#

# Evaluate `code` and format the result REPL-style, returning the rendered text
# and whether evaluation (or formatting) errored. The `errored` flag drives the
# response frame's type so the client can route failures and set its exit code.
function _evaluate(code::AbstractString, id::Integer, mod::Union{Module, Nothing})
    # Use the active module to maintain state between evaluations.
    # This allows users to define variables and use them in subsequent calls.
    mod = @something(mod, Base.active_module())
    try
        thunk = () -> include_string(mod, code, "REPL[$id]")
        # Capture stdout, stderr, logging, and the return value, giving us
        # REPL-like behavior. InterruptException is rethrown to allow
        # graceful interruption of long-running code.
        result = _capture(thunk)

        buffer = IOBuffer()
        # Stdout output comes first, just like in the REPL
        if !isempty(result.output)
            println(buffer, rstrip(result.output))
        end

        if result.error
            _error_message(buffer, result, id)
        else
            _echo_object(result.value) && _show_object(buffer, result, mod)
        end

        return (; output = String(take!(buffer)), errored = result.error)
    catch error
        # Guards failures in the result-formatting path (`_error_message`,
        # `_show_object`, `take!`). Evaluation errors are caught inside `_capture`
        # and reported through `result.error`.
        @error "Error evaluating code" id code error
        return (; output = "ERROR: $(error)", errored = true)
    end
end

_echo_object(object) = true

function _show_object(buffer, result, mod)
    # Mimic REPL display settings: limit output size, no color codes
    # (since we're sending over a socket), and use the correct module
    # context for printing types.
    ctx = IOContext(buffer, :limit => true, :color => false, :module => mod)
    # invokelatest: the value's type may have been defined during this same
    # request, after the worker's world age was fixed.
    return Base.invokelatest(show, ctx, "text/plain", result.value)
end

function _error_message(buffer, result, id)
    # Clean up the backtrace to match REPL behavior. We truncate at the
    # first "top-level scope" frame since everything above that is
    # internal REPLicant machinery that users don't need to see.
    bt = Base.scrub_repl_backtrace(result.backtrace::Vector)
    top_level = findfirst(x -> x.func === Symbol("top-level scope"), bt)
    bt = bt[1:something(top_level, length(bt))]

    print(buffer, "ERROR: ")
    # invokelatest: a user-defined exception type may have been created during
    # this request, after the worker's world age was fixed.
    return Base.invokelatest(showerror, buffer, result.value.error, bt)
end

#
# Revise integration.
#

# Two-layer dispatch pattern for optional dependency support.
# When Revise isn't loaded, __revise falls back to direct execution.
# When the extension loads, it overrides __revise to check for pending
# revisions before invoking the function.
_revise(f, args...; kws...) = __revise(nothing, f, args...; kws...)
__revise(::Any, f, args...; kws...) = f(args...; kws...)
