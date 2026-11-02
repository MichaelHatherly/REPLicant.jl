# How REPLicant works

1. The server lets the OS assign a free port and listens for
   length-prefixed requests.
2. It registers itself in an owner-only directory (`$REPLICANT_DIR`, else
   `tempdir()/replicant-<uid>`, or `tempdir()/replicant` on Windows), one
   `key=value` file per live server. The client reads that directory to find and
   select a target.
3. Code runs in a persistent module with `include_string`, so state survives
   between calls.
4. With Revise loaded, changed code reloads before each request.

REPLicant lives in the global environment, like Revise, and never becomes a
dependency of the project it serves. The `julia +rpc` client runs with no
`--project` and resolves `using REPLicant` from there.
