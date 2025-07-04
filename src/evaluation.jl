#
# Code evaluation and command dispatch
#

function _include_file_command(code::AbstractString, id::Integer, mod::Module)
    root = dirname(_find_just_file())
    path = joinpath(root, code)
    if isfile(path)
        # Include the file in the active module context
        @info "Including file" id path = Text(path)
        return () -> Base.include(mod, path)
    else
        error("File not found: $path")
    end
end

function _test_item_command(item::AbstractString, id::Integer, mod::Module)
    _try_load_test_item_runner(mod)
    code = "@run_package_tests filter=ti->ti.name == $(repr(item))"
    @info "Running test item" id code
    return () -> include_string(mod, code, "REPL[$id]")
end

function _test_tags_command(tags::AbstractString, id::Integer, mod::Module)
    _try_load_test_item_runner(mod)
    tags = Symbol.(split(strip(tags), ' '))
    code = "@run_package_tests filter=ti->issubset($(repr(tags)), ti.tags)"
    @info "Running tests with tags filter" id code
    return () -> include_string(mod, code, "REPL[$id]")
end

function _try_load_test_item_runner(mod::Module)
    # This command is used to run specific test items.
    # It expects a TestItemRunner to be available in the module context.
    if !isdefined(mod, :TestItemRunner)
        try
            Core.eval(mod, :(using TestItemRunner))
        catch error
            error("TestItemRunner not found in module context: $error")
        end
    end
end

function _eval_code(
    code::AbstractString,
    id::Integer,
    mod::Union{Module,Nothing},
    commands::Dict = Dict{String,Function}(),
)
    # Use the active module to maintain state between evaluations.
    # This allows users to define variables and use them in subsequent calls.
    mod = @something(mod, Base.active_module())
    try
        m = match(r"^#([a-z][a-z\-]+)\s+", code)
        thunk = if isnothing(m)
            () -> include_string(mod, code, "REPL[$id]")
        else
            command_string = m[1]
            default_commands = Dict(
                # Commands:
                "include-file" => _include_file_command,
                "test-item" => _test_item_command,
                "test-tags" => _test_tags_command,
                "meta" => _meta_command,
            )
            available_commands = merge(default_commands, commands)
            command = get(available_commands, command_string, nothing)
            if isnothing(command)
                error("Unknown command: $command_string")
            else
                # Call the command with the rest of the code
                command(lstrip(code[(length(m.match)+1):end]), id, mod)
            end
        end
        # IOCapture handles both stdout and the return value, giving us
        # REPL-like behavior. We rethrow InterruptException to allow
        # graceful interruption of long-running code.
        result = IOCapture.capture(thunk; rethrow = InterruptException)

        buffer = IOBuffer()
        # Stdout output comes first, just like in the REPL
        if !isempty(result.output)
            println(buffer, rstrip(result.output))
        end

        try
            if result.error
                _error_message(buffer, result, id)
            else
                _echo_object(result.value) && _show_object(buffer, result, mod)
            end
        catch error
            return "$error, $result"
        end

        return String(take!(buffer))
    catch error
        # This catches errors that occur outside of IOCapture,
        # such as syntax errors during parsing.
        @error "Error evaluating code" id code error
        return "ERROR: $(error)"
    end
end

_echo_object(object) = true

function _show_object(buffer, result, mod)
    # Mimic REPL display settings: limit output size, no color codes
    # (since we're sending over a socket), and use the correct module
    # context for printing types.
    ctx = IOContext(buffer, :limit => true, :color => false, :module => mod)
    show(ctx, "text/plain", result.value)
end

function _error_message(buffer, result, id)
    # Clean up the backtrace to match REPL behavior. We truncate at the
    # first "top-level scope" frame since everything above that is
    # internal REPLicant machinery that users don't need to see.
    bt = Base.scrub_repl_backtrace(result.backtrace::Vector)
    top_level = findfirst(x -> x.func === Symbol("top-level scope"), bt)
    bt = bt[1:something(top_level, length(bt))]

    print(buffer, "ERROR: ")
    showerror(buffer, result.value.error, bt)
end

#
# Revise integration
#

# Two-layer dispatch pattern for optional dependency support.
# When Revise isn't loaded, __revise falls back to direct execution.
# When the extension loads, it overrides __revise to check for pending
# revisions before invoking the function.
_revise(f, args...; kws...) = __revise(nothing, f, args...; kws...)
__revise(::Any, f, args...; kws...) = f(args...; kws...)
