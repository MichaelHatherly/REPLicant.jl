@testitem "justfiles" begin
    import REPLicant
    import Logging
    import Test

    @testset "Create new justfile" begin
        mktempdir() do dir
            cd(dir) do
                # Create justfile
                logger = Test.TestLogger()
                Logging.with_logger(logger) do
                    REPLicant.justfile()
                end
                @test length(logger.logs) == 1

                # Check it was created
                @test isfile("justfile")

                # Check content
                content = read("justfile", String)
                @test occursin("julia code:", content)
                @test occursin("docs binding:", content)
                @test occursin("test-all:", content)
                @test occursin("test-item item:", content)
            end
        end
    end

    @testset "Append to existing justfile without julia recipe" begin
        mktempdir() do dir
            cd(dir) do
                # Create existing justfile with different content
                existing_content = """
                # My custom recipes
                build:
                    echo "Building..."

                clean:
                    rm -rf build/
                """
                write("justfile", existing_content)

                # Add REPLicant recipes
                logger = Test.TestLogger()
                Logging.with_logger(logger) do
                    REPLicant.justfile()
                end
                @test length(logger.logs) == 1

                # Check content
                content = read("justfile", String)
                @test occursin("build:", content)  # Original content preserved
                @test occursin("clean:", content)  # Original content preserved
                @test occursin("# REPLicant recipes", content)
                @test occursin("julia code:", content)
                @test occursin("docs binding:", content)
            end
        end
    end

    @testset "Error when julia recipe exists" begin
        mktempdir() do dir
            cd(dir) do
                # Create justfile with julia recipe
                existing_content = """
                julia:
                    echo "My custom julia recipe"
                """
                write("justfile", existing_content)

                # Should throw error
                @test_throws ErrorException REPLicant.justfile()
            end
        end
    end

    @testset "Detect julia recipe with parameters" begin
        mktempdir() do dir
            cd(dir) do
                # Create justfile with julia recipe with parameters
                existing_content = """
                julia code flags:
                    echo "Running julia with {{code}} and {{flags}}"
                """
                write("justfile", existing_content)

                # Should throw error
                @test_throws ErrorException REPLicant.justfile()
            end
        end
    end

    @testset "Support different justfile names" begin
        # Test each supported name
        choices =
            ("Justfile", "justfile", "JUSTFILE", ".justfile", ".Justfile", ".JUSTFILE")
        for name in choices
            mktempdir() do dir
                cd(dir) do
                    # Create file with this name
                    write(name, "# Empty justfile\n")

                    # Add REPLicant recipes
                    logger = Test.TestLogger()
                    Logging.with_logger(logger) do
                        REPLicant.justfile()
                    end
                    @test length(logger.logs) == 1

                    # Check it was updated
                    content = read(name, String)
                    @test occursin("# REPLicant recipes", content)
                    @test occursin("julia code:", content)

                    # Verify only the named file exists (no extra "justfile" was created)
                    existing_files = filter(f -> f in choices, readdir())
                    @test length(existing_files) == 1
                    @test existing_files[1] == name
                end
            end
        end
    end

    @testset "Handle missing newline at end of file" begin
        mktempdir() do dir
            cd(dir) do
                # Create file without trailing newline
                write("justfile", "build:\n    echo 'building'")

                # Add REPLicant recipes
                logger = Test.TestLogger()
                Logging.with_logger(logger) do
                    REPLicant.justfile()
                end
                @test length(logger.logs) == 1

                # Check formatting is correct
                content = read("justfile", String)
                lines = split(content, '\n')

                # Should have empty line before "# REPLicant recipes"
                replicant_index = findfirst(==("# REPLicant recipes"), lines)
                @test replicant_index !== nothing
                @test lines[replicant_index-1] == ""
            end
        end
    end

    @testset "Recipe detection edge cases" begin
        mktempdir() do dir
            cd(dir) do
                # Test that commented julia recipe doesn't trigger error
                content = """
                # julia code:
                #     echo "commented out"

                build:
                    echo "building"
                """
                write("justfile", content)

                # Should not throw error
                logger = Test.TestLogger()
                Logging.with_logger(logger) do
                    REPLicant.justfile()
                end
                @test length(logger.logs) == 1
                updated = read("justfile", String)
                @test occursin("# REPLicant recipes", updated)

                # Clean up for next test
                for fname in
                    ["justfile", "Justfile", ".justfile", "Justfile.just", ".justfile.just"]
                    isfile(fname) && rm(fname)
                end

                # Test julia in middle of recipe name
                content = """
                compile_julia_code:
                    echo "not a julia recipe"
                """
                write("justfile", content)

                # Should not throw error
                REPLicant.justfile()
            end
        end
    end
end
