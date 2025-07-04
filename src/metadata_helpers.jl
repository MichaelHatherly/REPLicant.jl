#
# Helper functions for metadata inspection
#

function _get_function_signature(name::Symbol, obj, mod::Module)
    try
        meths = methods(obj)
        if isempty(meths)
            return "()"
        end

        # Get first method for display
        meth = first(meths)

        # Get location
        file, line = Base.functionloc(meth)
        if isnothing(file)
            location = "REPL"
        else
            location = _format_location(file, line)
        end

        # Get signature
        sig = meth.sig
        params = sig.parameters[2:end]  # Skip function type

        if isempty(params)
            sig_str = "()"
        else
            # Format parameter types
            param_strs = [string(T) for T in params]
            sig_str = "($(join(param_strs, ", ")))"
        end

        # Add method count if more than one
        if length(meths) > 1
            sig_str *= " +$(length(meths)-1) methods"
        end

        result = "$sig_str at $location"
        return result
    catch e
        # More detailed error handling
        @error "Failed to get signature for $name" exception = e
        return "()"  # Fallback for built-in functions
    end
end

function _get_type_info(T::Type)
    try
        if isabstracttype(T)
            super = supertype(T)
            return "<: $super (abstract)"
        else
            super = supertype(T)
            field_count = length(fieldnames(T))
            if field_count == 0
                return "<: $super"
            else
                return "<: $super with $field_count field$(field_count == 1 ? "" : "s")"
            end
        end
    catch
        return ":: Type"
    end
end

function _get_size_string(obj)
    try
        if isa(obj, AbstractArray)
            dims = size(obj)
            if length(dims) == 1
                return "($(dims[1]) elements)"
            else
                return "($(join(dims, "×")))"
            end
        elseif isa(obj, AbstractDict)
            n = length(obj)
            return "($(n) $(n == 1 ? "entry" : "entries"))"
        elseif isa(obj, AbstractString)
            n = length(obj)
            return "($(n) character$(n == 1 ? "" : "s"))"
        else
            return ""
        end
    catch
        return ""
    end
end

function _format_location(file::Union{AbstractString,Nothing}, line::Integer)
    # Handle nothing file
    if isnothing(file)
        return "unknown location"
    end

    # Handle REPL locations
    if occursin("REPL[", file)
        return file
    end

    # Try to make path relative to current directory
    try
        pwd_path = pwd()
        if startswith(file, pwd_path)
            rel_path = relpath(file, pwd_path)
            return "$rel_path:$line"
        end
    catch
    end

    # Try to shorten stdlib paths
    if occursin("julia", file) && occursin("stdlib", file)
        parts = split(file, "stdlib")
        if length(parts) >= 2
            return "stdlib" * parts[end] * ":$line"
        end
    end

    # Default: use full path
    return "$file:$line"
end

# Helper function to format bytes
function format_bytes(bytes::Integer)
    if bytes < 1024
        return "$bytes bytes"
    elseif bytes < 1024^2
        return Printf.@sprintf("%.2f KB", bytes / 1024)
    elseif bytes < 1024^3
        return Printf.@sprintf("%.2f MB", bytes / 1024^2)
    else
        return Printf.@sprintf("%.2f GB", bytes / 1024^3)
    end
end

function _highlight_type_instabilities(output::String, io::IO = IOBuffer())
    # Track issues found
    issues = String[]

    for line in split(output, '\n')
        # Highlight Any types (both lowercase and uppercase)
        if (occursin("::Any", line) || occursin("::ANY", line)) &&
           !occursin("Body::Any", line) &&
           !occursin("Body::ANY", line)
            push!(issues, "Type instability: " * strip(line))
        end

        # Check for Body::ANY or Body::UNION
        if occursin("Body::ANY", line)
            push!(issues, "Return type is unstable (Any)")
        elseif occursin("Body::UNION", line)
            push!(issues, "Return type is unstable (Union)")
        end

        # Highlight problematic Union types
        if occursin("::Union{", line) && !occursin("::Union{}", line)
            push!(issues, "Union type: " * strip(line))
        end

        # Highlight boxing
        if occursin("Box(", line)
            push!(issues, "Boxing allocation: " * strip(line))
        end

        println(io, line)
    end

    # Add summary at the end
    if !isempty(issues)
        println(io, format_section_header("Type Stability Issues", 2))
        for issue in issues
            println(io, format_list_item(issue, indent_level = 1, bullet = "⚠"))
        end
        println(io, format_section_header("Optimization Suggestions", 2))
        println(
            io,
            format_list_item(
                "Add type annotations to unstable variables",
                indent_level = 1,
            ),
        )
        println(
            io,
            format_list_item("Ensure function returns consistent types", indent_level = 1),
        )
        println(
            io,
            format_list_item(
                "Avoid type-unstable operations in hot loops",
                indent_level = 1,
            ),
        )
    else
        println(io, format_status("No type stability issues detected", :success))
    end

    String(take!(io))
end

function _analyze_llvm_output(llvm::String, io::IO)
    println(io, llvm)

    println(io, format_section_header("LLVM Analysis", 2))

    # Count allocations
    allocs = count("alloca", llvm)
    calls = count("call", llvm)

    println(io, format_key_value("Stack allocations", allocs))
    println(io, format_key_value("Function calls", calls))

    # Check for heap allocations
    if occursin("julia.gc_alloc", llvm)
        println(io, format_status("Heap allocations detected", :warning))
    end

    # Check for bounds checks
    if occursin("julia.bounds_check", llvm)
        println(io, format_status("Bounds checks present (use @inbounds to remove)", :info))
    end

    String(take!(io))
end

function _extract_performance_issues(warntype_output::String)
    issues = String[]

    for line in split(warntype_output, '\n')
        # Type instabilities (handle both Any and ANY)
        if (occursin("::Any", line) || occursin("::ANY", line)) &&
           !occursin("Body::Any", line) &&
           !occursin("Body::ANY", line)
            m = match(r"(\w+)::(Any|ANY)", line)
            if !isnothing(m)
                push!(issues, "Variable '$(m[1])' has unstable type Any")
            end
        end

        # Check for unstable return type
        if occursin("Body::ANY", line)
            push!(issues, "Function returns unstable type (Any)")
        elseif occursin("Body::UNION", line)
            push!(issues, "Function returns unstable type (Union)")
        end

        # Union types
        if occursin("::Union{", line)
            m = match(r"(\w+)::Union{([^}]+)}", line)
            if !isnothing(m)
                push!(issues, "Variable '$(m[1])' has union type: Union{$(m[2])}")
            end
        end

        # Boxing
        if occursin("%box", line) || occursin("Box(", line)
            push!(issues, "Boxing allocation detected: $line")
        end
    end

    unique!(issues)
    return issues
end

function _generate_optimization_suggestions(issues::Vector{String}, warntype_output::String)
    suggestions = String[]

    # Type instability suggestions
    if any(occursin("unstable type Any", issue) for issue in issues)
        push!(suggestions, "Add type assertions or ensure consistent return types")
        push!(
            suggestions,
            "Consider splitting polymorphic code into separate type-stable functions",
        )
    end

    # Union type suggestions
    if any(occursin("union type", issue) for issue in issues)
        push!(suggestions, "Avoid mixing Nothing/Missing with other types in hot code")
        push!(suggestions, "Use Union splitting or handle cases separately")
    end

    # Allocation suggestions
    if any(occursin("Boxing allocation", issue) for issue in issues)
        push!(suggestions, "Avoid capturing variables that change type in closures")
        push!(suggestions, "Pre-allocate arrays and reuse buffers")
    end

    # General suggestions based on patterns
    if occursin("@inbounds", warntype_output)
        push!(suggestions, "Consider using @inbounds after validating array access")
    end

    if occursin("AbstractArray", warntype_output) ||
       occursin("AbstractVector", warntype_output)
        push!(
            suggestions,
            "Use concrete array types in function signatures for better performance",
        )
    end

    return suggestions
end

#
# Dependency analysis functions
#

function _extract_dependencies(func::Function, types::Type)
    deps = Set{String}()

    # Get lowered code
    try
        code = Base.code_lowered(func, types)

        for method_code in code
            _extract_calls_from_code(method_code, deps)
        end
    catch
        # Some methods might not be analyzable
    end

    return sort(collect(deps))
end

function _extract_calls_from_code(code::Core.CodeInfo, deps::Set{String})
    for stmt in code.code
        if isa(stmt, Expr)
            _extract_calls_from_expr(stmt, deps)
        elseif isa(stmt, GlobalRef)
            # Handle GlobalRef directly
            push!(deps, "$(stmt.mod).$(stmt.name)")
        end
    end
end

function _extract_calls_from_expr(expr::Expr, deps::Set{String})
    if expr.head == :call
        # Direct function call
        if length(expr.args) >= 1
            func_expr = expr.args[1]

            if isa(func_expr, GlobalRef)
                # Fully qualified call
                push!(deps, "$(func_expr.mod).$(func_expr.name)")
            elseif isa(func_expr, Symbol)
                # Local or imported call
                push!(deps, string(func_expr))
            elseif isa(func_expr, Expr) && func_expr.head == :.
                # Dot call like Module.func
                push!(deps, string(func_expr))
            end
        end
    elseif expr.head in [:invoke, :foreigncall]
        # Handle special call types
        if expr.head == :invoke && length(expr.args) >= 2
            meth = expr.args[1]
            if isa(meth, Core.MethodInstance)
                push!(deps, string(meth.def.name))
            end
        end
    end

    # Recurse into sub-expressions
    for arg in expr.args
        if isa(arg, Expr)
            _extract_calls_from_expr(arg, deps)
        end
    end
end

function _format_method_signature(meth::Method)
    sig = meth.sig
    # Handle UnionAll types by getting the body
    sig_type = sig isa UnionAll ? sig.body : sig
    params = sig_type.parameters[2:end]  # Skip function type
    param_strs = [string(T) for T in params]
    return "$(meth.name)($(join(param_strs, ", ")))"
end

function _try_get_location(dep::String, mod::Module)
    # Try to parse the dependency and find its location
    parts = split(dep, '.')

    try
        if length(parts) >= 2
            # Module.function format
            mod_name = Symbol(parts[1])
            func_name = Symbol(parts[end])

            if isdefined(Main, mod_name)
                target_mod = getfield(Main, mod_name)
                if isdefined(target_mod, func_name)
                    func = getfield(target_mod, func_name)
                    if isa(func, Function)
                        meths = methods(func)
                        if !isempty(meths)
                            file, line = Base.functionloc(first(meths))
                            return _format_location(file, line)
                        end
                    end
                end
            end
        else
            # Simple function name
            func_name = Symbol(dep)
            if isdefined(mod, func_name)
                func = getfield(mod, func_name)
                if isa(func, Function)
                    meths = methods(func)
                    if !isempty(meths)
                        file, line = Base.functionloc(first(meths))
                        return _format_location(file, line)
                    end
                end
            end
        end
    catch
        # Failed to resolve location
    end

    return nothing
end

function _function_calls_target(func::Function, target::Symbol, mod::Module)
    for meth in methods(func)
        try
            sig = meth.sig
            # Handle UnionAll types by getting the body
            sig_type = sig isa UnionAll ? sig.body : sig
            types = Tuple{sig_type.parameters[2:end]...}

            code = Base.code_lowered(func, types)
            for method_code in code
                if _code_contains_call(method_code, target)
                    return true
                end
            end
        catch
            # Some methods might not be analyzable
            continue
        end
    end
    return false
end

function _code_contains_call(code::Core.CodeInfo, target::Symbol)
    for stmt in code.code
        if isa(stmt, Expr) && _expr_contains_call(stmt, target)
            return true
        elseif isa(stmt, GlobalRef)
            # Check if this is a direct call to the target
            if stmt.name == target
                return true
            end
        end
    end
    return false
end

function _expr_contains_call(expr::Expr, target::Symbol)
    if expr.head == :call && length(expr.args) >= 1
        func_expr = expr.args[1]

        if func_expr == target
            return true
        elseif isa(func_expr, GlobalRef) && func_expr.name == target
            return true
        elseif isa(func_expr, Expr) && func_expr.head == :. && length(func_expr.args) >= 2
            # Check for Module.target calls
            if func_expr.args[2] isa QuoteNode && func_expr.args[2].value == target
                return true
            end
        end
    end

    # Recurse into sub-expressions
    for arg in expr.args
        if isa(arg, Expr) && _expr_contains_call(arg, target)
            return true
        end
    end

    return false
end

function _build_call_graph(
    func_sym::Symbol,
    mod::Module,
    graph::Dict,
    visited::Set,
    depth::Int,
    max_depth::Int,
)
    func_name = string(func_sym)

    # Avoid cycles and depth limit
    if func_name in visited || depth >= max_depth
        return
    end

    push!(visited, func_name)

    if isdefined(mod, func_sym)
        obj = getfield(mod, func_sym)
        if isa(obj, Function) || (isa(obj, Type) && obj <: Function)
            deps = String[]

            # Get dependencies for all methods
            for meth in methods(obj)
                try
                    sig = meth.sig
                    # Handle UnionAll types by getting the body
                    sig_type = sig isa UnionAll ? sig.body : sig
                    types = Tuple{sig_type.parameters[2:end]...}
                    method_deps = _extract_dependencies(obj, types)
                    append!(deps, method_deps)
                catch e
                    # Skip methods that can't be analyzed
                    continue
                end
            end

            unique!(deps)
            graph[func_name] = deps

            # Recurse
            for dep in deps
                dep_sym = _parse_function_name(dep, mod)
                if !isnothing(dep_sym)
                    _build_call_graph(dep_sym, mod, graph, visited, depth + 1, max_depth)
                end
            end
        end
    end
end

function _parse_function_name(dep::String, mod::Module)
    # Extract function name from dependency string
    parts = split(dep, '.')

    try
        if length(parts) >= 2
            # Module.function format - get just the function name
            return Symbol(parts[end])
        else
            # Simple function name
            return Symbol(dep)
        end
    catch
        return nothing
    end
end

function _print_simple_call_tree(
    io::IO,
    node::String,
    graph::Dict,
    prefix::String,
    visited::Set{String},
)
    # Avoid printing cycles
    if node in visited
        println(io, prefix, "└─ ", node, " [circular]")
        return
    end

    push!(visited, node)
    println(io, prefix, "└─ ", node)

    if haskey(graph, node)
        children = graph[node]
        for (i, child) in enumerate(children)
            is_last = i == length(children)
            child_prefix = prefix * (is_last ? "   " : "│  ")

            # Display dependency directly without recursion
            child_name = split(child, '.')[end]
            println(io, child_prefix, "└─ ", child_name)
        end
    end

    delete!(visited, node)
end

function _find_functions_using_type(T::Type, mod::Module)
    results = Tuple{String,String}[]

    for name in names(mod; all = true)
        isdefined(mod, name) || continue

        # Skip compiler-generated names
        startswith(string(name), "#") && continue

        obj = getfield(mod, name)

        if isa(obj, Function) || (isa(obj, Type) && obj <: Function)
            for meth in methods(obj)
                # Check parameters
                for (i, param_type) in enumerate(meth.sig.parameters[2:end])
                    if _type_uses_type(param_type, T)
                        push!(results, (string(name), "argument $i"))
                        break
                    end
                end

                # Check return type if available
                # This is harder to do statically, would need type inference
            end
        end
    end

    return unique(results)
end

function _type_uses_type(haystack::Type, needle::Type)
    if haystack == needle
        return true
    elseif haystack isa UnionAll
        return _type_uses_type(haystack.body, needle)
    elseif haystack isa Union
        return any(t -> _type_uses_type(t, needle), Base.uniontypes(haystack))
    elseif haystack <: Tuple
        return any(t -> _type_uses_type(t, needle), haystack.parameters)
    elseif haystack <: Array && length(haystack.parameters) > 0
        return _type_uses_type(haystack.parameters[1], needle)
    end
    return false
end

function _find_types_containing(T::Type, mod::Module)
    results = String[]

    for name in names(mod; all = true)
        isdefined(mod, name) || continue

        # Skip compiler-generated names
        startswith(string(name), "#") && continue

        obj = getfield(mod, name)

        if isa(obj, Type) && !(obj <: Function) && isconcretetype(obj)
            # Check fields
            for (fname, ftype) in zip(fieldnames(obj), fieldtypes(obj))
                if _type_uses_type(ftype, T)
                    push!(results, "$name.$fname :: $ftype")
                end
            end
        end
    end

    return results
end
