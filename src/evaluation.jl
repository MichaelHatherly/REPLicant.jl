#
# Output capture.
#
# Output is routed per task rather than redirected process-wide. A remote eval
# binds `CAPTURE_TARGET` to its own pipe for the eval's dynamic extent; the
# routing IO and display steer Julia-level writes to that pipe when bound and
# to the real streams otherwise. The eval also redirects the raw fds 1/2 to the
# same pipe, so subprocess and C-library output is captured too. The interactive
# REPL's output, running with no binding, reaches the terminal even while an eval
# is in flight.

# The process's real streams, captured when routing is installed. These TTYs write
# to the terminal through their own libuv handles, independent of fd 1/2. Idle,
# their fds back fd 1/2; during an eval `_capture` redirects fd 1/2 to its pipe and
# restores these afterward. The routers steer Julia-level writes to them when no
# capture target is bound.
const REAL_OUT = Ref{IO}()
const REAL_ERR = Ref{IO}()

# The current eval's capture target, or `nothing` when no eval is active. Bound by
# `with(CAPTURE_TARGET => pipe.in)` and, on 1.11+, inherited by child tasks the
# eval spawns. `_capture` binds the pipe's write end, a `LibuvStream` whose `write`
# locks internally, so concurrent writes from inherited tasks stay safe.
const CAPTURE_TARGET = ScopedValue{Union{IO, Nothing}}(nothing)

# Routing stream installed via `redirect_stdout`/`redirect_stderr`, reading its
# real stream from `real` (`REAL_OUT` for stdout, `REAL_ERR` for stderr).
# `pipe_writer` returns that fd-backed stream so the redirect dups its fd unchanged;
# `write`/`unsafe_write` steer to the bound capture target, else the real stream.
# Property queries (`:color`, `displaysize`) delegate to the active stream so the
# router impersonates it: the idle REPL sees the real TTY (color on, real size),
# captured output sees the plain buffer (color off). `redirect_stdout` reads
# `get(stdout, :color)` when building the REPL, so this keeps the prompt colored.
struct Router <: Base.AbstractPipe
    real::Base.RefValue{IO}
end
_routed(r::Router) = something(CAPTURE_TARGET[], r.real[])
Base.pipe_writer(r::Router) = r.real[]  # dendro-ignore: duplicate -- forwarding accessor to the backing stream
Base.pipe_reader(r::Router) = r.real[]  # dendro-ignore: duplicate -- forwarding accessor to the backing stream
Base.unsafe_write(r::Router, p::Ptr{UInt8}, n::UInt) = unsafe_write(_routed(r), p, n)
Base.write(r::Router, b::UInt8) = write(_routed(r), b)
Base.flush(r::Router) = flush(_routed(r))  # dendro-ignore: duplicate -- one-line delegation to the routed stream
Base.get(r::Router, key::Symbol, default) = get(_routed(r), key, default)
Base.displaysize(r::Router) = displaysize(_routed(r))  # dendro-ignore: duplicate -- one-line delegation to the routed stream

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
    redirect_stdout(Router(REAL_OUT))
    redirect_stderr(Router(REAL_ERR))
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

# `_redirect_io_libc` dups a stream's fd, so it needs an fd-backed stream. Julia
# wraps `stdout` in an `IOContext` when color is forced (CI, `--color=yes`); unwrap
# to the stream underneath. The routers still write to the full `IOContext`, so
# `:color` and the rest carry through; only the fd redirect needs the bare stream.
_fd_stream(io::IO) = io
_fd_stream(io::Base.IOContext) = _fd_stream(io.io)

# Run `f` with its output captured, returning the captured text alongside the
# value (or the thrown exception and its backtrace). InterruptException is rethrown
# so long-running code stays interruptible.
#
# A single pipe sinks every strand of the eval's output in write order: the
# routers and the display steer Julia-level writes there via `CAPTURE_TARGET`, the
# logger writes its records there, and fd 1/2 are redirected to it so subprocess
# and C-library output land there too. fd 1 is process-global, so a subprocess
# launched at the REPL prompt during an eval is captured into that eval; the worker
# is sequential, so this is rare and accepted.
function _capture(f)
    # Capture routes through the installed streams. The server installs them at
    # start; install here too so a direct `_capture` (e.g. a test) still routes.
    _install_routing!()

    pipe = Pipe()
    Base.link_pipe!(pipe; reader_supports_async = true, writer_supports_async = true)
    # Redirect only the raw fds, not the global `stdout`/`stderr` bindings: those
    # stay the routers. `_redirect_io_libc` is the primitive `redirect_stdout`
    # calls; it dups the fd portably (Windows `SetStdHandle` handled internally).
    Base._redirect_io_libc(pipe.in, 1)
    Base._redirect_io_libc(pipe.in, 2)
    logger = Logging.ConsoleLogger(pipe.in)

    # Spawning the reader task draws from the task RNG; copy and restore it so
    # user code sees an unperturbed random stream.
    old_rng = copy(Random.default_rng())
    buffer = IOBuffer()
    reader = @async write(buffer, pipe)
    copy!(Random.default_rng(), old_rng)

    value, errored, backtrace = with(CAPTURE_TARGET => pipe.in) do
        Logging.with_logger(logger) do
            try
                yield()  # let the reader task start draining the pipe
                f(), false, Vector{Ptr{Cvoid}}()
            catch err
                err isa InterruptException && rethrow()
                # `include_string` wraps an interrupt thrown in user code as a
                # `LoadError`. Report it to the client like any error, but with no
                # backtrace: the exception was delivered asynchronously at an
                # arbitrary point, and walking that stack under threads deadlocks in
                # the runtime's stack lookup.
                interrupted = err isa LoadError && err.error isa InterruptException
                err, true, (interrupted ? Ptr{Cvoid}[] : catch_backtrace())
            finally
                # Drain libc's own stdio buffers into the pipe before restoring
                # the fds, so fully-buffered C output (e.g. `puts`) is captured
                # rather than flushed to the terminal at process exit.
                Base.Libc.flush_cstdio()
                Base._redirect_io_libc(_fd_stream(REAL_OUT[]), 1)
                Base._redirect_io_libc(_fd_stream(REAL_ERR[]), 2)
                close(pipe.in)
                wait(reader)
            end
        end
    end

    return (
        output = String(take!(buffer)),
        value = value,
        error = errored,
        backtrace = backtrace,
    )
end

#
# Code evaluation.
#

# Evaluate `code` in `mod`, formatting the result REPL-style and returning the
# rendered text and whether evaluation (or formatting) errored. The `errored` flag
# drives the response frame's type so the client can route failures and set its exit
# code. `dir` is the caller's working directory (empty keeps the server's cwd). The
# module is resolved by the dispatcher (see `_request_module`) before this runs.
function _evaluate(code::AbstractString, id::Integer, mod::Module, dir::AbstractString)
    if _is_help_query(code)
        query = chop(lstrip(code); head = 1, tail = 0)  # drop one leading `?`
        return _help(query, mod)
    end
    try
        thunk = () -> include_string(mod, code, "REPL[$id]")
        # Capture stdout, stderr, logging, and the return value, giving us
        # REPL-like behavior. InterruptException is rethrown to allow
        # graceful interruption of long-running code. Run in the caller's directory
        # when given so relative paths resolve there; `cd` restores the previous
        # directory on return or throw, so a `cd` inside the eval never leaks. Safe
        # because the worker is sequential.
        result = isempty(dir) ? _capture(thunk) : cd(() -> _capture(thunk), dir)

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

# Named sessions are kept in the server's `SessionStore`, each a standalone module
# reused across calls. Storing them there (rather than as bindings in the eval
# module) keeps `Main` clean and sidesteps the binding-partition rules that make a
# redefined module binding unreliable; reset is a plain Dict write, visible at once.

# Build a fresh session module named `sym`. `Module` carries the standard `Base`
# imports; wire `include` to the module itself, the way a `module ... end` block
# would, so script files and `include` run inside it.
function _new_session(sym::Symbol)
    mod = Module(sym)
    Core.eval(mod, :(include(path) = $(Base.include)($mod, path)))
    return mod
end

# The default session is addressed by omitting `--module`. A named session called
# "Main" would be a distinct module (`Main.Main`) shadowing that name, so reject it
# rather than hand back a decoy the caller mistakes for the default.
_reject_reserved_session(name::AbstractString) =
    name == "Main" && error("Main is the default session; omit --module to use it")

# The module a request evaluates into: the default session (the server's module, or
# `Main`) when no `--module` is given, else the named session. Called by the
# dispatcher when a request is accepted, so the eval's module is fixed before any
# later reset can swap it.
function _request_module(srv::Server, name::AbstractString)
    isempty(name) && return @something(srv.mod, Base.active_module())
    _reject_reserved_session(name)
    return _session_module(srv.sessions, name)
end

# Resolve a named session module, creating it on first use. State defined in one
# call is visible in the next under the same name.
function _session_module(sessions::SessionStore, name::AbstractString)
    return Base.@lock sessions.lock get!(() -> _new_session(Symbol(name)), sessions.modules, name)
end

# Replace the named session with a fresh, empty module, giving a clean slate
# without restarting the process. The old module is unreferenced and gets
# collected. The default session is the process's `Main` and cannot be reset, so a
# name is required.
function _reset_session(srv::Server, name::AbstractString)
    isempty(name) && error("reset needs a module name; the default session cannot be reset")
    _reject_reserved_session(name)
    Base.@lock srv.sessions.lock srv.sessions.modules[name] = _new_session(Symbol(name))
    return "reset module $name"
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
    # Clean up the backtrace to match REPL behavior. Truncate at the first
    # "top-level scope" frame, since everything below is internal REPLicant
    # machinery. An error raised while evaluating the top-level expression itself
    # (an undefined binding) has no such frame, so fall back to the eval entry: cut
    # just above the first `include_string` frame, which leaves no machinery, as the
    # REPL shows for that error.
    bt = Base.scrub_repl_backtrace(result.backtrace::Vector)
    cut = findfirst(x -> x.func === Symbol("top-level scope"), bt)
    if isnothing(cut)
        entry = findfirst(x -> x.func === :include_string, bt)
        cut = isnothing(entry) ? length(bt) : entry - 1
    end
    bt = bt[1:cut]

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

# One animation frame of a busy prompt, generic across REPL modes. `base` is the
# idle prompt text (`"julia> "`, `"pkg> "`, `"help?> "`, ...); `marker` is its
# last non-blank glyph, the `>`-style cursor common to every mode. A `_` sweeps
# through the label before the marker, swapping one width-1 glyph for another, so
# `textwidth(base)` holds and the cursor never shifts.
function _busy_frame(base::AbstractString, n::Int)
    chars = collect(Char, base)
    marker = length(chars)
    while marker > 0 && isspace(chars[marker])
        marker -= 1
    end
    marker == 0 && return String(chars)
    span = max(marker - 1, 1)
    chars[mod(n, span) + 1] = '_'
    return String(chars)
end

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
function _evaluate_request(code::AbstractString, id::Integer, mod::Module, dir::AbstractString)
    _notify_busy(1)
    return try
        _evaluate(code, id, mod, dir)
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
