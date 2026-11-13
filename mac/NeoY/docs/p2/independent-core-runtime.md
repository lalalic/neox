# Independently managed native Rust Core

NeoY.app owns the signed macOS trust boundary and the lifecycle of a single,
independently versioned Rust Core MCP child. There is no Node/npm Core fallback.

- Seed: `Neo.app/Contents/Resources/neoy-core-rust`, signed individually inside
  the signed native app. Developer checkout and npm are not needed on first run.
- Managed binaries: `~/Library/Application Support/NeoY/core/rust/versions/<semver>/neoy-core-rust`.
- `current`: atomic symlink to an immutable version directory. `previous-version`
  identifies the last healthy version for rollback.
- Data: original `NEO_CORE_DATA_DIR` remains unchanged. Historical jobs, PTY
  metadata and configuration are preserved.
- Native startup checks actual `initialize` and `tools/list` with a disposable
  data directory; if active Core is unhealthy, select previous healthy version
  or quarantine damaged version and recover from the signed seed. No Node subprocess.

## Explicit upgrades

`neo setup core status` shows the installed native Rust version.
`neo setup core upgrade bundled` selects the signed app seed; `neo setup core
upgrade /absolute/path/to/neoy-core-rust` accepts only a valid locally signed
Rust executable from the same Developer Team as the signed app. The candidate
must return `--version` and pass the real MCP handshake before activation;
post-activation failure switches back to the previous healthy version.
`neo setup core rollback` rechecks and selects `previous-version`.

No registry polling or automatic code download occurs. Installing a newer signed
Neo.app seeds a newer Rust release only after it passes the same probe. Changes
reconcile the single `core` provider without restarting unrelated providers.

## Verification

- `ManagedRustCoreRuntimeTests`: fresh install, healthy restart, signed-seed
  update, rollback, quarantine of damaged version, failed upgrade and real
  executable MCP handshake.
- `cargo test --locked --manifest-path mac/NeoY/CoreRust/Cargo.toml` runs the
  native Core protocol, tool/GC, shell/filesystem/PTY/Codex tests without Node.
- `mac/NeoY/install-local.sh` is the one approved native app installation path,
  including Rust build/signing, app watchdog and live gateway health check.
