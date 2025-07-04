#
# Metadata inspection commands
#

function _meta_command(code::AbstractString, id::Integer, mod::Module)
    parts = split(strip(code), ' ', limit = 3)
    subcommand = length(parts) >= 1 ? parts[1] : "list"
    args = length(parts) >= 2 ? join(parts[2:end], ' ') : ""

    if subcommand == "list"
        filter = strip(args)
        return () -> _meta_list(mod, filter)
    elseif subcommand == "info"
        object_name = strip(args)
        if isempty(object_name)
            return () -> "ERROR: Object name required. Usage: #meta info <object_name>"
        end
        return () -> _meta_info(mod, object_name)
    elseif subcommand == "typed"
        return _meta_typed_command(args, id, mod)
    elseif subcommand == "warntype"
        return _meta_warntype_command(args, id, mod)
    elseif subcommand == "llvm"
        return _meta_llvm_command(args, id, mod)
    elseif subcommand == "native"
        return _meta_native_command(args, id, mod)
    elseif subcommand == "optimize"
        return _meta_optimize_command(args, id, mod)
    elseif subcommand == "deps"
        return _meta_deps_command(args, id, mod)
    elseif subcommand == "callers"
        return _meta_callers_command(args, id, mod)
    elseif subcommand == "graph"
        return _meta_graph_command(args, id, mod)
    elseif subcommand == "uses"
        return _meta_uses_command(args, id, mod)
    else
        error(
            "Unknown meta subcommand: $subcommand. Available: list, info, typed, warntype, llvm, native, optimize, deps, callers, graph, uses",
        )
    end
end

function _meta_list(mod::Module, filter::AbstractString = "")
    io = IOBuffer()

    # Get all names in the module
    all_names = names(mod; all = true, imported = true)

    # Categorize objects
    functions = Tuple{Symbol,String}[]
    types = Tuple{Symbol,String}[]
    modules = Symbol[]
    variables = Tuple{Symbol,String,String}[]

    for name in all_names
        # Skip compiler-generated names
        startswith(string(name), "#") && continue

        # Skip if not defined
        isdefined(mod, name) || continue

        # Skip private names unless specifically requested
        if isempty(filter) && startswith(string(name), "_")
            continue
        end

        obj = getfield(mod, name)

        # Categorize based on type
        if isa(obj, Module) && obj !== mod
            push!(modules, name)
        elseif isa(obj, Type) && !(obj <: Function)
            # It's a type (but not a function type)
            type_info = _get_type_info(obj)
            push!(types, (name, type_info))
        elseif isa(obj, Function) || (isa(obj, Type) && obj <: Function)
            # It's a function or callable type
            sig_info = _get_function_signature(name, obj, mod)
            push!(functions, (name, sig_info))
        else
            # It's a variable
            type_str = string(typeof(obj))
            size_str = _get_size_string(obj)
            push!(variables, (name, type_str, size_str))
        end
    end

    # Apply filter if specified
    if !isempty(filter)
        filter_lower = lowercase(filter)
        if filter_lower in ["function", "functions"]
            types = empty!(types)
            modules = empty!(modules)
            variables = empty!(variables)
        elseif filter_lower in ["type", "types"]
            functions = empty!(functions)
            modules = empty!(modules)
            variables = empty!(variables)
        elseif filter_lower in ["module", "modules"]
            functions = empty!(functions)
            types = empty!(types)
            variables = empty!(variables)
        elseif filter_lower in ["variable", "variables", "var", "vars"]
            functions = empty!(functions)
            types = empty!(types)
            modules = empty!(modules)
        else
            return "Unknown filter: $filter. Available: functions, types, modules, variables"
        end
    end

    # Format header
    header_title = if isempty(filter)
        "Objects in $mod"
    else
        "$(uppercasefirst(filter)) in $mod"
    end
    println(io, format_section_header(header_title))

    # Sort each category
    sort!(functions; by = first)
    sort!(types; by = first)
    sort!(modules)
    sort!(variables; by = first)

    # Display functions
    if !isempty(functions)
        println(io, format_section_header("Functions", 2))
        println(io, format_count("Function", length(functions)))
        for (name, sig) in functions
            if isempty(sig)
                println(io, format_list_item("$name", indent_level = 1))
            else
                println(io, format_list_item("$name$sig", indent_level = 1))
            end
        end
    end

    # Display types
    if !isempty(types)
        println(io, format_section_header("Types", 2))
        println(io, format_count("Type", length(types)))
        for (name, info) in types
            println(io, format_list_item("$name $info", indent_level = 1))
        end
    end

    # Display modules
    if !isempty(modules)
        println(io, format_section_header("Modules", 2))
        println(io, format_count("Module", length(modules)))
        for name in modules
            println(io, format_list_item("$name", indent_level = 1))
        end
    end

    # Display variables
    if !isempty(variables)
        println(io, format_section_header("Variables", 2))
        println(io, format_count("Variable", length(variables)))
        for (name, type_str, size_str) in variables
            println(io, format_list_item("$name :: $type_str $size_str", indent_level = 1))
        end
    end

    # Summary
    if isempty(filter)
        println(io, format_section_header("Summary", 2))
        println(
            io,
            format_object_summary(
                length(functions),
                length(types),
                length(modules),
                length(variables),
            ),
        )
    end

    return String(take!(io))
end

#
# Meta info commands
#

function _meta_info(mod::Module, object_name::AbstractString)
    # Parse object name
    sym = Symbol(object_name)

    # Check if object exists
    if !isdefined(mod, sym)
        return "ERROR: Object '$object_name' not found in module $mod"
    end

    # Get the object
    obj = getfield(mod, sym)

    # Dispatch based on type
    if isa(obj, Module)
        return _meta_info_module(sym, obj, mod)
    elseif isa(obj, Type) && !(obj <: Function)
        return _meta_info_type(sym, obj, mod)
    elseif isa(obj, Function) || (isa(obj, Type) && obj <: Function)
        return _meta_info_function(sym, obj, mod)
    else
        return _meta_info_variable(sym, obj, mod)
    end
end

function _meta_info_function(name::Symbol, func, mod::Module)
    io = IOBuffer()

    # Header
    println(io, format_section_header("Function: $name"))

    # Get all methods
    meths = methods(func)

    # Methods section
    println(io, format_section_header("Signatures", 2))
    println(io, format_key_value("Methods", length(meths)))

    # List each method with location
    for (i, method) in enumerate(meths)
        file, line = Base.functionloc(method)
        location = isnothing(file) ? "unknown location" : _format_location(file, line)

        # Get signature
        sig = method.sig
        params = sig.parameters[2:end]  # Skip function type
        param_strs = String[]

        # Format parameters
        for T in params
            push!(param_strs, string(T))
        end

        sig_str = "$(name)($(join(param_strs, ", ")))"
        println(io, format_list_item("$sig_str at $location", indent_level = 1))
    end

    # Documentation
    doc = Base.Docs.doc(func)
    doc_str = string(doc)
    if !isempty(doc_str) && doc_str != "No documentation found."
        println(io, format_section_header("Documentation", 2))
        for line in split(doc_str, '\n')
            println(io, "  $line")
        end
    end

    # Properties section
    println(io, format_section_header("Properties", 2))
    println(io, format_key_value("Generic function", true, indent_level = 1))
    println(io, format_key_value("Module", parentmodule(func), indent_level = 1))

    return String(take!(io))
end

function _meta_info_type(name::Symbol, T::Type, mod::Module)
    io = IOBuffer()

    # Header
    println(io, "Type: $name")
    println(io, "="^(6 + length(string(name))))

    # Type hierarchy
    println(io, "\nSupertype: $(supertype(T))")

    # Check if abstract
    if isabstracttype(T)
        println(io, "Abstract: true")

        # Show subtypes if any
        subs = InteractiveUtils.subtypes(T)
        if !isempty(subs)
            println(io, "\nSubtypes: $(length(subs))")
            for (i, sub) in enumerate(subs)
                if i <= 10  # Show first 10
                    println(io, "  - $sub")
                end
            end
            if length(subs) > 10
                println(io, "  ... and $(length(subs) - 10) more")
            end
        end
    else
        println(io, "Abstract: false")

        # Fields
        fnames = fieldnames(T)
        ftypes = fieldtypes(T)
        println(io, "\nFields: $(length(fnames))")
        if !isempty(fnames)
            for (fname, ftype) in zip(fnames, ftypes)
                println(io, "  $fname :: $ftype")
            end
        end

        # Constructors
        constructors = methods(T)
        if length(constructors) > 0
            println(io, "\nConstructors: $(length(constructors))")
            for (i, method) in enumerate(constructors)
                if i <= 5  # Show first 5
                    sig = method.sig
                    params = sig.parameters[2:end]
                    param_strs = [string(T) for T in params]
                    println(io, "  $name($(join(param_strs, ", ")))")
                end
            end
            if length(constructors) > 5
                println(io, "  ... and $(length(constructors) - 5) more")
            end
        end
    end

    # Size if concrete
    if isconcretetype(T)
        println(io, "\nSize: $(sizeof(T)) bytes")
    end

    # Documentation
    doc = Base.Docs.doc(T)
    doc_str = string(doc)
    if !isempty(doc_str) && doc_str != "No documentation found."
        println(io, "\nDocumentation:")
        for line in split(doc_str, '\n')
            println(io, "  ", line)
        end
    end

    return String(take!(io))
end

function _meta_info_module(name::Symbol, mod::Module, parent_mod::Module)
    io = IOBuffer()

    # Header
    println(io, "Module: $name")
    println(io, "="^(8 + length(string(name))))

    # Parent module
    println(io, "\nParent: $(parentmodule(mod))")

    # Count contents
    all_names = names(mod; all = true, imported = false)
    exported = names(mod; all = false)

    # Exports
    println(io, "\nExports: $(length(exported))")
    if !isempty(exported)
        # Group by type
        exp_funcs = Symbol[]
        exp_types = Symbol[]
        exp_other = Symbol[]

        for exp in exported
            if isdefined(mod, exp)
                obj = getfield(mod, exp)
                if isa(obj, Function) || (isa(obj, Type) && obj <: Function)
                    push!(exp_funcs, exp)
                elseif isa(obj, Type)
                    push!(exp_types, exp)
                else
                    push!(exp_other, exp)
                end
            end
        end

        if !isempty(exp_funcs)
            println(io, "  Functions:")
            for f in exp_funcs[1:min(10, length(exp_funcs))]
                println(io, "    - $f")
            end
            if length(exp_funcs) > 10
                println(io, "    ... and $(length(exp_funcs) - 10) more")
            end
        end

        if !isempty(exp_types)
            println(io, "  Types:")
            for t in exp_types[1:min(10, length(exp_types))]
                println(io, "    - $t")
            end
            if length(exp_types) > 10
                println(io, "    ... and $(length(exp_types) - 10) more")
            end
        end

        if !isempty(exp_other)
            println(io, "  Other:")
            for o in exp_other[1:min(10, length(exp_other))]
                println(io, "    - $o")
            end
            if length(exp_other) > 10
                println(io, "    ... and $(length(exp_other) - 10) more")
            end
        end
    end

    println(io, "\nTotal names: $(length(all_names))")

    # Path if it's a package
    if isdefined(mod, :__file__)
        println(io, "File: $(mod.__file__)")
    end

    # Documentation
    doc = Base.Docs.doc(mod)
    doc_str = string(doc)
    if !isempty(doc_str) && doc_str != "No documentation found."
        println(io, "\nDocumentation:")
        for line in split(doc_str, '\n')
            println(io, "  ", line)
        end
    end

    return String(take!(io))
end

function _meta_info_variable(name::Symbol, obj, mod::Module)
    io = IOBuffer()

    # Header
    println(io, "Variable: $name")
    println(io, "="^(10 + length(string(name))))

    # Type
    T = typeof(obj)
    println(io, "\nType: $T")

    # Size information
    try
        size_bytes = Base.summarysize(obj)
        println(io, "Size: $(format_bytes(size_bytes))")
    catch
        # Some objects can't be sized
    end

    # Special handling for collections
    if isa(obj, AbstractArray)
        println(io, "\nArray information:")
        println(io, "  Dimensions: $(join(size(obj), " × "))")
        println(io, "  Element type: $(eltype(obj))")
        println(io, "  Total elements: $(length(obj))")

        # Show first few elements if small
        if length(obj) <= 10
            println(io, "  Values: ", obj)
        end
    elseif isa(obj, AbstractDict)
        println(io, "\nDictionary information:")
        println(io, "  Entries: $(length(obj))")
        println(io, "  Key type: $(keytype(obj))")
        println(io, "  Value type: $(valtype(obj))")

        # Show first few entries if small
        if length(obj) <= 5
            println(io, "  Contents:")
            for (k, v) in obj
                println(io, "    $k => $v")
            end
        end
    elseif isa(obj, AbstractString)
        println(io, "\nString information:")
        println(io, "  Length: $(length(obj)) characters")
        if length(obj) <= 200
            println(io, "  Content: \"$obj\"")
        else
            println(io, "  Preview: \"$(first(obj, 100))...\"")
        end
    elseif isa(obj, AbstractSet)
        println(io, "\nSet information:")
        println(io, "  Elements: $(length(obj))")
        println(io, "  Element type: $(eltype(obj))")

        if length(obj) <= 10
            println(io, "  Contents: ", obj)
        end
    end

    # Show value for simple types
    if isa(obj, Number) || isa(obj, Symbol) || isa(obj, Bool)
        println(io, "\nValue: $obj")
    end

    # Check if mutable
    println(io, "\nMutable: $(ismutable(obj))")

    return String(take!(io))
end

#
# Performance introspection functions
#

function _parse_call_expression(expr_str::String, mod::Module)
    # Parse "funcname (Type1, Type2, ...)"
    m = match(r"^\s*(\w+)\s*\((.*)\)\s*$", expr_str)
    if isnothing(m)
        error("Invalid syntax. Use: #meta typed funcname (Type1, Type2, ...)")
    end

    func_name = Symbol(m[1])
    args_str = m[2]

    # Parse argument types
    if isempty(strip(args_str))
        arg_types = Tuple{}
    else
        # Evaluate each type in the module context
        type_exprs = split(args_str, ',')
        types = []
        for t in type_exprs
            stripped = strip(t)
            if !isempty(stripped)
                type_expr = Meta.parse(stripped)
                type_val = Core.eval(mod, type_expr)
                push!(types, type_val)
            end
        end
        # Create the tuple type properly
        arg_types = Tuple{types...}
    end

    return func_name, arg_types
end

function _meta_typed_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        if !isdefined(mod, func_name)
            error("Function $func_name not found")
        end

        func = getfield(mod, func_name)

        # Get typed code
        code_info = Base.code_typed(func, arg_types; optimize = true)

        if isempty(code_info)
            return "No methods match the given argument types"
        end

        io = IOBuffer()
        println(io, format_section_header("Type-inferred code for $func_name$arg_types"))

        # Show the typed code
        for (i, (ci, ret_type)) in enumerate(code_info)
            if length(code_info) > 1
                println(io, format_section_header("Method $i", 2))
            end
            println(io, format_key_value("Return type", ret_type))
            println(io)

            # Display code with line numbers
            Base.IRShow.show_ir(io, ci)
        end

        String(take!(io))
    end
end

function _meta_warntype_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)

        io = IOBuffer()
        println(
            io,
            format_section_header("Type stability analysis for $func_name$arg_types"),
        )
        println(io)

        # Use InteractiveUtils.code_warntype
        try
            # Import code_warntype from InteractiveUtils
            InteractiveUtils.code_warntype(io, func, arg_types)
        catch e
            println(io, "ERROR: Failed to analyze function: ", e)
        end

        output = String(take!(io))
        io = IOBuffer()

        # Post-process to highlight issues
        _highlight_type_instabilities(output, io)
    end
end

function _meta_llvm_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)

        io = IOBuffer()
        println(io, format_section_header("LLVM IR for $func_name$arg_types"))
        println(io)

        # Get LLVM code using InteractiveUtils.code_llvm
        try
            InteractiveUtils.code_llvm(io, func, arg_types; debuginfo = :none)
        catch e
            println(io, "ERROR: Failed to generate LLVM code: ", e)
        end

        output = String(take!(io))
        io = IOBuffer()

        # Add analysis
        _analyze_llvm_output(output, io)
    end
end

function _meta_native_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)

        io = IOBuffer()
        println(io, format_section_header("Native assembly for $func_name$arg_types"))
        println(io)

        # Get native code using InteractiveUtils.code_native
        try
            InteractiveUtils.code_native(io, func, arg_types; debuginfo = :none)
        catch e
            println(io, "ERROR: Failed to generate native code: ", e)
        end
        String(take!(io))
    end
end

function _meta_optimize_command(expr::String, id::Integer, mod::Module)
    return () -> begin
        func_name, arg_types = _parse_call_expression(expr, mod)

        func = getfield(mod, func_name)
        io = IOBuffer()

        println(io, format_section_header("Performance Analysis: $func_name$arg_types"))

        # 1. Type inference results
        println(io, format_section_header("Type Inference", 2))
        code_info = Base.code_typed(func, arg_types; optimize = true)
        if !isempty(code_info)
            ci, ret_type = code_info[1]
            println(io, format_key_value("Return type", ret_type, indent_level = 1))

            # Check for type stability
            stable = ret_type != Any && !isa(ret_type, Union)
            status_msg =
                stable ? format_status("Yes", :success) : format_status("No", :error)
            println(io, format_key_value("Type stable", status_msg, indent_level = 1))
        end

        # 2. Identify allocations and instabilities
        println(io, format_section_header("Performance Issues", 2))

        # Run code_warntype analysis
        warntype_io = IOBuffer()
        try
            InteractiveUtils.code_warntype(warntype_io, func, arg_types)
        catch e
            println(warntype_io, "ERROR: Failed to analyze function: ", e)
        end
        warntype_output = String(take!(warntype_io))

        issues = _extract_performance_issues(warntype_output)

        if isempty(issues)
            println(io, format_status("No major performance issues detected", :success))
        else
            println(io, format_count("Issue", length(issues)))
            for issue in issues
                println(io, format_list_item("$issue", indent_level = 1))
            end
        end

        # 3. Optimization suggestions
        println(io, format_section_header("Optimization Suggestions", 2))
        suggestions = _generate_optimization_suggestions(issues, warntype_output)

        if isempty(suggestions)
            println(io, format_status("No specific suggestions available", :info))
        else
            for suggestion in suggestions
                println(io, format_list_item("$suggestion", indent_level = 1))
            end
        end

        # 4. Allocation summary
        println(io, format_section_header("Memory Analysis", 2))
        println(
            io,
            format_key_value(
                "Note",
                "Run @allocated $func_name(...) for allocation data",
                indent_level = 1,
            ),
        )

        String(take!(io))
    end
end

#
# Dependency analysis functions
#

function _meta_deps_command(func_name::String, id::Integer, mod::Module)
    return () -> begin
        sym = Symbol(strip(func_name))

        if !isdefined(mod, sym)
            return "ERROR: Function $func_name not found in module $mod"
        end

        obj = getfield(mod, sym)
        if !isa(obj, Function) && !(isa(obj, Type) && obj <: Function)
            return "ERROR: $func_name is not a function"
        end

        io = IOBuffer()
        println(io, format_section_header("Dependencies of $func_name"))
        println(io)

        # Get all methods
        meths = methods(obj)

        all_deps = Dict{String,Vector{String}}()

        for meth in meths
            try
                sig = meth.sig
                # Handle UnionAll types by getting the body
                sig_type = sig isa UnionAll ? sig.body : sig
                types = Tuple{sig_type.parameters[2:end]...}

                deps = _extract_dependencies(obj, types)

                sig_str = _format_method_signature(meth)
                all_deps[sig_str] = deps
            catch e
                # Skip methods that can't be analyzed
                continue
            end
        end

        # Display dependencies by method
        for (sig, deps) in all_deps
            println(io, format_section_header("Method: $sig", 3))
            if isempty(deps)
                println(io, format_status("No dependencies detected", :info))
            else
                println(io, format_count("Dependency", length(deps), plural_suffix = "ies"))
                for dep in deps
                    # Try to get location info
                    loc = _try_get_location(dep, mod)
                    if isnothing(loc)
                        println(io, format_list_item("$dep", indent_level = 1))
                    else
                        println(io, format_list_item("$dep at $loc", indent_level = 1))
                    end
                end
            end
        end

        # Summary
        all_unique_deps = union(values(all_deps)...)
        println(io, format_section_header("Summary", 2))
        println(io, format_key_value("Total unique dependencies", length(all_unique_deps)))

        String(take!(io))
    end
end

function _meta_callers_command(func_name::String, id::Integer, mod::Module)
    return () -> begin
        target_sym = Symbol(strip(func_name))

        if !isdefined(mod, target_sym)
            return "ERROR: Function $func_name not found in module $mod"
        end

        io = IOBuffer()
        println(io, format_section_header("Functions that call $func_name"))
        println(io)

        callers = Set{String}()

        # Search through all functions in module
        for name in names(mod; all = true)
            isdefined(mod, name) || continue

            # Skip compiler-generated names
            startswith(string(name), "#") && continue

            obj = getfield(mod, name)

            (isa(obj, Function) || (isa(obj, Type) && obj <: Function)) || continue

            # Skip self
            name == target_sym && continue

            # Check if this function calls our target
            if _function_calls_target(obj, target_sym, mod)
                push!(callers, string(name))
            end
        end

        if isempty(callers)
            println(io, format_status("No callers found in module $mod", :info))
        else
            println(io, format_count("Caller", length(callers)))
            for caller in sort(collect(callers))
                # Get location
                caller_func = getfield(mod, Symbol(caller))
                meths = methods(caller_func)
                if !isempty(meths)
                    file, line = Base.functionloc(first(meths))
                    location = _format_location(file, line)
                    println(io, format_list_item("$caller at $location", indent_level = 1))
                else
                    println(io, format_list_item("$caller", indent_level = 1))
                end
            end
        end

        println(io, format_section_header("Summary", 2))
        println(io, format_key_value("Total callers", length(callers)))

        String(take!(io))
    end
end

function _meta_graph_command(func_name::String, id::Integer, mod::Module)
    return () -> begin
        sym = Symbol(strip(func_name))

        if !isdefined(mod, sym)
            return "ERROR: Function $func_name not found in module $mod"
        end

        io = IOBuffer()
        println(io, format_section_header("Call graph starting from $func_name"))
        println(io)

        # Build graph with depth limit
        visited = Set{String}()
        graph = Dict{String,Vector{String}}()

        _build_call_graph(sym, mod, graph, visited, 0, 3)

        # Display as simple tree
        _print_simple_call_tree(io, string(sym), graph, "", Set{String}())

        println(io, format_section_header("Summary", 2))
        println(io, format_key_value("Nodes in graph", length(graph)))

        String(take!(io))
    end
end

function _meta_uses_command(type_name::String, id::Integer, mod::Module)
    return () -> begin
        sym = Symbol(strip(type_name))

        if !isdefined(mod, sym)
            return "ERROR: Type $type_name not found in module $mod"
        end

        obj = getfield(mod, sym)
        if !isa(obj, Type)
            return "ERROR: $type_name is not a type"
        end

        io = IOBuffer()
        println(io, format_section_header("Usage of type $type_name"))

        # Find functions that use this type
        println(io, format_section_header("Functions with $type_name in signature", 2))
        functions_using = _find_functions_using_type(obj, mod)

        if isempty(functions_using)
            println(io, format_status("None found", :info))
        else
            println(io, format_count("Function", length(functions_using)))
            for (func_name, usage_type) in functions_using
                println(io, format_list_item("$func_name ($usage_type)", indent_level = 1))
            end
        end

        # Find types that contain this type
        println(io, format_section_header("Types containing $type_name", 2))
        types_containing = _find_types_containing(obj, mod)

        if isempty(types_containing)
            println(io, format_status("None found", :info))
        else
            println(io, format_count("Type", length(types_containing)))
            for type_info in types_containing
                println(io, format_list_item("$type_info", indent_level = 1))
            end
        end

        String(take!(io))
    end
end
