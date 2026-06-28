@testitem "help_query_detection" tags = [:help_mode] begin
    @test REPLicant._is_help_query("?x")
    @test REPLicant._is_help_query("  ?x")
    @test !REPLicant._is_help_query("x")
    @test !REPLicant._is_help_query("")
end

@testitem "help_doc_fallback" tags = [:help_mode] begin
    mod = Module()
    # A non-`nothing` first arg always dispatches to the `@doc` fallback, even when
    # the REPL extension is loaded, so this exercises the headless path directly.
    @test contains(REPLicant.__help(0, "println", mod).output, "println")
    @test !REPLicant.__help(0, "println", mod).errored

    # Operators resolve through `@doc` too.
    @test contains(REPLicant.__help(0, "+", mod).output, "+")

    # An undefined binding is graceful: no docs, no error.
    undefined = REPLicant.__help(0, "nonexistent_xyz", mod)
    @test !undefined.errored
    @test contains(undefined.output, "No documentation found")
end

@testitem "help_full_helpmode" tags = [:help_mode] begin
    # Loading REPL activates the extension, overriding `__help(::Nothing, ...)`
    # with the full `helpmode`. Only `helpmode` documents keywords, so the `for`
    # doc confirms the extension path. End-to-end through `_evaluate` exercises the
    # `?`-strip and dispatch.
    import REPL
    mod = Module()
    result = REPLicant._evaluate("?for", 1, mod, "")
    @test !result.errored
    @test contains(result.output, "for")
    @test contains(result.output, "loop")
end
