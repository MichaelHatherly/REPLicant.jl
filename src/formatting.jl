#
# Formatting utilities for consistent output
#

# Section separators and status indicators
const MAJOR_SEP = "="
const MINOR_SEP = "-"
const CHECK = "✓"
const CROSS = "✗"
const WARN = "⚠"
const INFO = "ℹ"
const INDENT = "  "

# Format a section header with appropriate separator
function format_section_header(title::String, level::Int = 1)
    if level == 1
        sep_len = max(20, length(title) + 4)
        return "$title\n$(MAJOR_SEP^sep_len)"
    elseif level == 2
        return "\n## $title"
    else
        return "\n$title:"
    end
end

# Format a key-value pair with optional indentation
function format_key_value(key::String, value::Any; indent_level::Int = 0)
    indent = INDENT^indent_level
    return "$indent$key: $value"
end

# Format a list item with bullet and indentation
function format_list_item(item::String; indent_level::Int = 0, bullet::String = "-")
    indent = INDENT^indent_level
    if isempty(bullet)
        return "$indent$item"
    else
        return "$indent$bullet $item"
    end
end

# Format status message with appropriate indicator
function format_status(message::String, status::Symbol = :info)
    indicator = if status == :success
        CHECK
    elseif status == :error
        CROSS
    elseif status == :warning
        WARN
    else
        INFO
    end
    return "$indicator $message"
end

# Format a count with category
function format_count(category::String, count::Int; plural_suffix::String = "s")
    if count == 1
        return "$category ($count):"
    else
        # Handle special plurals like "ies" for words ending in "y"
        if plural_suffix == "ies" && endswith(category, "y")
            plural_form = category[1:(end-1)] * "ies"
        else
            plural_form = category * plural_suffix
        end
        return "$plural_form ($count):"
    end
end

# Truncate long outputs with informative message
function truncate_output(str::String; max_lines::Int = 50, max_chars::Int = 2000)
    lines = split(str, '\n')

    if length(lines) > max_lines
        truncated = join(lines[1:max_lines], '\n')
        return truncated * "\n... ($(length(lines) - max_lines) more lines)"
    elseif length(str) > max_chars
        return str[1:max_chars] * "\n... ($(length(str) - max_chars) more characters)"
    else
        return str
    end
end

# Format error message with context and suggestions
function format_error_message(
    error_type::String,
    message::String,
    suggestions::Vector{String} = String[],
)
    io = IOBuffer()
    println(io, "ERROR: $error_type")
    println(io, "  $message")

    if !isempty(suggestions)
        println(io, "\nSuggestions:")
        for suggestion in suggestions
            println(io, "  - $suggestion")
        end
    end

    return String(take!(io))
end

# Format object summary with counts
function format_object_summary(funcs::Int, types::Int, modules::Int, vars::Int)
    total = funcs + types + modules + vars
    parts = String[]

    funcs > 0 && push!(parts, "$funcs function$(funcs == 1 ? "" : "s")")
    types > 0 && push!(parts, "$types type$(types == 1 ? "" : "s")")
    modules > 0 && push!(parts, "$modules module$(modules == 1 ? "" : "s")")
    vars > 0 && push!(parts, "$vars variable$(vars == 1 ? "" : "s")")

    if isempty(parts)
        return "Total: 0 objects"
    else
        return "Total: $total objects ($(join(parts, ", ")))"
    end
end
