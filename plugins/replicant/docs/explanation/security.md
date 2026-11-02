# Security model

REPLicant executes arbitrary code with full system access. Only run it in
trusted environments.

- The server listens on loopback only. Each server generates a random token at
  startup and writes it into its registry entry. A request without that token is
  rejected, so another local user cannot run code through your port.
- Before sending its token or code, the client checks that the server holds that token: the
  server answers a random challenge with an HMAC keyed by it. A process listening
  on a dead server's port cannot pass as the server or see what you send it.
- On Unix the registry directory is forced to mode `0700`. REPLicant refuses a
  registry directory owned by another user.
- Anything running as your user can read the token, the same way it could read
  your files.
- Executed code has the same permissions as the Julia process.
