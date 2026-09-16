# Shared wallet vault

This directory is the single source of truth for the encrypted wallet vault:

- `src/main.rs` defines the authenticated vault format and KDF parameters.
- `build.sh` is the only vault build/test entrypoint used by wallet images.
- `launcher.sh` owns open/create/session/save/cleanup and layout migration.
- `smoke-test.sh` is the runtime create/unpack/wrong-password check.

To add a wallet, keep wallet-specific paths and UI in its launcher, define the
five UI adapters documented at the top of `launcher.sh`, source the image-local
copy, then call `vault_configure` with the wallet-specific paths and type. Copy
the shared build, launcher, and smoke-test files from the `shared` build context
and merge
`&mgla-vault-resources` in `compose.yaml`.
