#
# Restart in place.
#

# The directory the process launched in. A relative `--project` or script path in
# the launch argv resolves against it, and an interactive `cd` may have moved away.
const LAUNCH_DIR = Ref("")

# Set once a restart begins, so the server's `atexit` hook leaves its listener open.
const RESTARTING = Ref(false)

# Restart replaces the process image with `execv`, which Windows lacks, and reads the
# launch argv from the OS, which only these platforms expose here.
function _check_restartable()
    (Sys.isapple() || Sys.islinux()) ||
        throw(RequestError("restart is supported on macOS and Linux only"))
    return nothing
end

# The argv the process launched with. Julia keeps only the script's `ARGS`, so read
# the full vector from the OS. A `/proc` cmdline ends each argument with a NUL.
function _launch_argv()
    @static if Sys.isapple()
        argc = unsafe_load(ccall(:_NSGetArgc, Ptr{Cint}, ()))
        argv = unsafe_load(ccall(:_NSGetArgv, Ptr{Ptr{Ptr{UInt8}}}, ()))
        return [unsafe_string(unsafe_load(argv, index)) for index in 1:argc]
    else
        return split(chop(read("/proc/self/cmdline", String)), '\0')
    end
end

# Replace this process with a fresh Julia on the same argv, environment, and
# terminal, keeping its pid. The `atexit` hooks run first, as on `exit`, so the
# registry entry is removed and the footer hands back its row; the terminal goes back
# to cooked mode, since the REPL may hold it raw. Returns only if `execv` fails.
function _reexec()
    argv = String.(_launch_argv())
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    RESTARTING[] = true
    Base._atexit(Cint(0))
    # End the prompt line, so the new session's banner starts on a line of its own.
    isinteractive() && println(stdout)
    flush(stdout)
    flush(stderr)
    ccall(:uv_tty_reset_mode, Cint, ())
    # An eval still running holds fd 1/2 on its capture, which `execv` would hand
    # the new process in place of the terminal.
    ROUTING_INSTALLED[] && _restore_real_fds()
    cd(LAUNCH_DIR[])
    pointers = Ptr{UInt8}[pointer.(argv); C_NULL]
    GC.@preserve argv ccall(:execv, Cint, (Cstring, Ptr{Ptr{UInt8}}), julia, pointers)
    @error "REPLicant restart failed; the server is no longer registered" error =
        Libc.strerror(Libc.errno())
    return nothing
end
