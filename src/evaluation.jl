#
# Output capture.
#
# Output is routed per task rather than redirected process-wide. A remote eval
# binds `CAPTURE_TARGET` to its own buffer for the eval's dynamic extent; the
# routing IO and display steer Julia-level writes to that buffer when bound and
# to the real streams otherwise. The interactive REPL's output, running with no
# binding, reaches the terminal even while an eval is in flight.

# The process's real streams, captured when routing is installed. `redirect_stdout`
# dups these fd-backed streams' fds back onto fd 1/2, so raw fd writes (subprocess,
# C library) still reach the terminal; the routers steer only Julia-level writes.
const REAL_OUT = Ref{IO}()
const REAL_ERR = Ref{IO}()

# The current eval's capture buffer, or `nothing` when no eval is active. Bound by
# `with(CAPTURE_TARGET => buf)` and, on 1.11+, inherited by child tasks the eval
# spawns. `_capture` binds a `LockedIO`, so concurrent writes from inherited tasks
# serialize.
const CAPTURE_TARGET = ScopedValue{Union{IO, Nothing}}(nothing)

# Serializes writes to an `IOBuffer`. Inherited child tasks can write to the same
# capture buffer concurrently, and `IOBuffer` is not thread-safe.
struct LockedIO <: Base.AbstractPipe
    buffer::IOBuffer
    lock::ReentrantLock
end
LockedIO(buffer::IOBuffer) = LockedIO(buffer, ReentrantLock())

Base.pipe_writer(l::LockedIO) = l.buffer
Base.unsafe_write(l::LockedIO, p::Ptr{UInt8}, n::UInt) = @lock l.lock unsafe_write(l.buffer, p, n)
Base.write(l::LockedIO, b::UInt8) = @lock l.lock write(l.buffer, b)

# Routing streams installed via `redirect_stdout`/`redirect_stderr`. `pipe_writer`
# returns the captured fd-backed stream so the redirect dups its fd unchanged;
# `write`/`unsafe_write` steer to the bound capture target, else the real stream.
# Property queries (`:color`, `displaysize`) delegate to the active stream so the
# router impersonates it: the idle REPL sees the real TTY (color on, real size),
# captured output sees the plain buffer (color off). `redirect_stdout` reads
# `get(stdout, :color)` when building the REPL, so this keeps the prompt colored.
struct RouterOut <: Base.AbstractPipe end
Base.pipe_writer(::RouterOut) = REAL_OUT[]
Base.pipe_reader(::RouterOut) = REAL_OUT[]
_routed_out() = something(CAPTURE_TARGET[], REAL_OUT[])
Base.unsafe_write(r::RouterOut, p::Ptr{UInt8}, n::UInt) = unsafe_write(_routed_out(), p, n)
Base.write(r::RouterOut, b::UInt8) = write(_routed_out(), b)
Base.flush(r::RouterOut) = flush(_routed_out())
Base.get(r::RouterOut, key::Symbol, default) = get(_routed_out(), key, default)
Base.displaysize(r::RouterOut) = displaysize(_routed_out())

struct RouterErr <: Base.AbstractPipe end
Base.pipe_writer(::RouterErr) = REAL_ERR[]
Base.pipe_reader(::RouterErr) = REAL_ERR[]
_routed_err() = something(CAPTURE_TARGET[], REAL_ERR[])
Base.unsafe_write(r::RouterErr, p::Ptr{UInt8}, n::UInt) = unsafe_write(_routed_err(), p, n)
Base.write(r::RouterErr, b::UInt8) = write(_routed_err(), b)
Base.flush(r::RouterErr) = flush(_routed_err())
Base.get(r::RouterErr, key::Symbol, default) = get(_routed_err(), key, default)
Base.displaysize(r::RouterErr) = displaysize(_routed_err())

# Routes `display(x)` to the bound capture target. With none bound it declines via
# a `MethodError`, so the global display stack falls through to the next display
# (the REPL's, which reaches the terminal). Mirrors `Base.Multimedia.TextDisplay`.
struct RouterDisplay <: Base.AbstractDisplay end

function Base.display(d::RouterDisplay, M::MIME"text/plain", x)
    target = CAPTURE_TARGET[]
    target === nothing && throw(MethodError(display, (d, M, x)))
    return show(target, M, x)
end
Base.display(d::RouterDisplay, x) = display(d, MIME"text/plain"(), x)

# Install the routing streams and display once. Idempotent so several servers in
# one process share a single installation. Headless servers route too; with no
# capture target bound, every write reaches the real streams.
const ROUTING_INSTALLED = Ref(false)

function _install_routing!()
    ROUTING_INSTALLED[] && return nothing
    REAL_OUT[] = stdout
    REAL_ERR[] = stderr
    redirect_stdout(RouterOut())
    redirect_stderr(RouterErr())
    pushdisplay(RouterDisplay())
    ROUTING_INSTALLED[] = true
    return nothing
end

function _uninstall_routing!()
    ROUTING_INSTALLED[] || return nothing
    redirect_stdout(REAL_OUT[])
    redirect_stderr(REAL_ERR[])
    popdisplay()
    ROUTING_INSTALLED[] = false
    return nothing
end

# Run `f` with its Julia-level output captured, returning the captured text
# alongside the value (or the thrown exception and its backtrace).
# InterruptException is rethrown so long-running code stays interruptible.
function _capture(f)
    # Capture routes through the installed streams. The server installs them at
    # start; install here too so a direct `_capture` (e.g. a test) still routes.
    _install_routing!()
    target = LockedIO(IOBuffer())
    logger = Logging.ConsoleLogger(target)

    value, errored, backtrace = with(CAPTURE_TARGET => target) do
        Logging.with_logger(logger) do
            try
                f(), false, Vector{Ptr{Cvoid}}()
            catch err
                err isa InterruptException && rethrow()
                err, true, catch_backtrace()
            end
        end
    end

    return (
        output = @lock(target.lock, String(take!(target.buffer))),
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
    if _is_help_query(code)
        query = chop(lstrip(code); head = 1, tail = 0)  # drop one leading `?`
        return _help(query, mod)
    end
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
# The REPL prints nothing for a `nothing` result; match that rather than echoing
# the literal "nothing". `display`, which returns `nothing`, is the common case.
_echo_object(::Nothing) = false

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
# Help mode.
#

# A query whose first non-space character is `?` asks for documentation, matching
# the REPL's help mode. `?x` is brief help, `??x` extended.
_is_help_query(code::AbstractString) = startswith(lstrip(code), '?')

# Render a docs object (Markdown.MD, or nothing for apropos) to plain text.
function _render_md(docs, mod::Module)
    docs === nothing && return ""
    buffer = IOBuffer()
    show(IOContext(buffer, :color => false, :module => mod), MIME"text/plain"(), docs)
    return String(take!(buffer))
end

# Two-layer dispatch, mirroring `_revise`. The REPL extension overrides
# `__help(::Nothing, ...)` with the full `helpmode` (operators, keywords, macros,
# apropos). Without REPL, the `::Any` fallback uses `@doc`, which covers bindings,
# operators, and macros.
_help(query::AbstractString, mod::Module) = __help(nothing, query, mod)

function __help(::Any, query::AbstractString, mod::Module)
    expr = Meta.parse(query; raise = false)
    docs = try
        Core.eval(
            mod,
            Expr(
                :macrocall,
                GlobalRef(Core, Symbol("@doc")),
                LineNumberNode(@__LINE__, Symbol(@__FILE__)),
                expr,
            ),
        )
    catch
        nothing
    end
    isnothing(docs) && return (; output = "No documentation found for `$query`.", errored = false)
    return (; output = _render_md(docs, mod), errored = false)
end

#
# Busy indicator.
#

# Depth of in-flight remote evaluations. A counter, not a flag, so overlapping or
# nested signals compose; the worker is sequential today, so depth is 0 or 1.
const REMOTE_EVAL_DEPTH = Threads.Atomic{Int}(0)

# True while at least one remote evaluation is running. Read from the REPL render
# thread by the prompt; the atomic gives a consistent value.
_is_busy() = REMOTE_EVAL_DEPTH[] > 0

# Two-layer dispatch, mirroring `_revise`/`_help`. The REPL extension overrides
# `__notify_busy(::Nothing)` to recolor the prompt and set the terminal title.
# Without REPL the `::Any` fallback does nothing.
function _notify_busy(delta::Int)
    Threads.atomic_add!(REMOTE_EVAL_DEPTH, delta)
    __notify_busy(nothing)
    return nothing
end
__notify_busy(::Any) = nothing

# Evaluate a remote request while signaling the prompt that work is in flight.
# Pings never reach here, so the indicator reflects only real evaluations.
function _evaluate_request(code::AbstractString, id::Integer, mod::Union{Module, Nothing})
    _notify_busy(1)
    return try
        _evaluate(code, id, mod)
    finally
        _notify_busy(-1)
    end
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
