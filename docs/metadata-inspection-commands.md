# Metadata Inspection Commands

REPLicant provides powerful metadata inspection commands that allow you to explore and analyze your Julia code interactively. These commands are designed to provide structured, AI-friendly output that helps both human developers and AI assistants understand code organization, dependencies, and performance characteristics.

## Overview

All metadata inspection commands use the `#meta` prefix followed by a subcommand. The output follows consistent formatting patterns with clear visual hierarchy, status indicators, and structured sections.

## Available Commands

### 1. Object Listing

#### `#meta list [filter]`
Lists all defined objects in the current module with optional filtering.

**Examples:**
```julia
#meta list              # List all objects
#meta list functions    # List only functions
#meta list types        # List only types
#meta list variables    # List only variables
#meta list modules      # List only modules
```

**Output Format:**
```
Objects in Main
====================

## Functions
Function (1):
  - process_data(Vector{Float64}) at src/data.jl:45

## Types
Type (1):
  - Config <: Any with 5 fields

## Summary
Total: 2 objects (1 function, 1 type)
```

### 2. Object Information

#### `#meta info <name>`
Shows detailed information about a specific object (function, type, module, or variable).

**Examples:**
```julia
#meta info myfunction   # Get info about a function
#meta info MyType       # Get info about a type
#meta info myvar        # Get info about a variable
#meta info MyModule     # Get info about a module
```

**Output includes:**
- **Functions**: Signatures, methods, source locations, documentation
- **Types**: Fields, constructors, supertypes, subtypes, size
- **Variables**: Type, size, dimensions (for arrays), preview
- **Modules**: Exports, parent module, total names

### 3. Performance Analysis

#### `#meta typed <function> (<types>)`
Shows type-inferred code for optimized performance analysis.

**Example:**
```julia
#meta typed process_data (Vector{Float64},)
```

#### `#meta warntype <function> (<types>)`
Analyzes type stability and highlights performance issues.

**Example:**
```julia
#meta warntype compute (Int, Float64)
```

**Output includes:**
- Type stability warnings
- Boxing allocations
- Union types
- Optimization suggestions

#### `#meta optimize <function> (<types>)`
Comprehensive performance analysis with recommendations.

**Example:**
```julia
#meta optimize heavy_computation (Matrix{Float64},)
```

**Output sections:**
- Type inference results
- Performance issues
- Optimization suggestions
- Memory analysis tips

#### `#meta llvm <function> (<types>)`
Shows LLVM intermediate representation with analysis.

**Example:**
```julia
#meta llvm fast_math (Float64, Float64)
```

#### `#meta native <function> (<types>)`
Shows native assembly code for the target architecture.

**Example:**
```julia
#meta native simple_add (Int, Int)
```

### 4. Dependency Analysis

#### `#meta deps <function>`
Shows what functions a given function calls (its dependencies).

**Example:**
```julia
#meta deps process_pipeline
```

**Output Format:**
```
Dependencies of process_pipeline
===================================

Method: process_pipeline(String)
Dependency (3):
  - load_data at src/io.jl:12
  - validate_input at src/validation.jl:45
  - transform_data at src/transform.jl:78

## Summary
Total unique dependencies: 3
```

#### `#meta callers <function>`
Shows what functions call a given function (reverse dependencies).

**Example:**
```julia
#meta callers validate_input
```

#### `#meta graph <function>`
Displays a call graph starting from the specified function.

**Example:**
```julia
#meta graph main
```

**Output Format:**
```
Call graph starting from main
================================

└─ main
   └─ parse_args
   └─ load_config
   └─ process_data
      └─ validate_input
      └─ transform

## Summary
Nodes in graph: 6
```

#### `#meta uses <type>`
Shows where a type is used in function signatures and other types.

**Example:**
```julia
#meta uses Config
```

## Output Formatting

All commands use consistent formatting patterns:

### Status Indicators
- ✓ Success/positive status
- ✗ Error/negative status
- ⚠ Warning/caution
- ℹ Information/note

### Section Headers
- Level 1: Title with equals separator
- Level 2: ## Section
- Level 3: Subsection:

### Counts
- Singular: "Function (1):"
- Plural: "Functions (3):"

## Use Cases

### 1. Code Exploration
Use `#meta list` and `#meta info` to understand available objects and their properties in an unfamiliar codebase.

### 2. Performance Optimization
Use `#meta optimize`, `#meta warntype`, and `#meta typed` to identify and fix performance bottlenecks.

### 3. Refactoring
Use `#meta deps`, `#meta callers`, and `#meta graph` to understand code dependencies before making changes.

### 4. Documentation
Use `#meta info` to quickly check documentation and signatures without leaving the REPL.

### 5. AI-Assisted Development
The structured output format is designed to be easily parsed by AI assistants, enabling them to:
- Understand code organization
- Identify optimization opportunities
- Navigate complex dependency graphs
- Provide informed suggestions

## Tips

1. **Argument Types**: When specifying types for performance commands, use Julia syntax:
   ```julia
   #meta typed myfunction (Int,)           # Single argument
   #meta typed myfunction (Int, Float64)   # Multiple arguments
   #meta typed myfunction ()               # No arguments
   ```

2. **Module Context**: Commands operate in the current module context. Use module-qualified names for objects in other modules.

3. **Error Messages**: All commands provide helpful error messages with suggestions when objects are not found or syntax is incorrect.

4. **Performance**: The dependency analysis commands have a depth limit to prevent excessive recursion in large codebases.