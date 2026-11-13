# NeoY native Rust Core

NeoY's only Core runtime is `neoy-core-rust`, a private, signed stdio MCP child
behind the existing NeoY authenticated gateway. This is the single executor for
`shell`, `fs`, `terminal`, `codex`, `apply_file_patch` and other Core tools.
Node Core, its npm package, differential runtime, and provider fallback are
retired. Unrelated Node services such as Markcut, WebHelm, Neo Harness and
Events Bus are not changed.

## Build, version and test

```sh
cd mac/NeoY/CoreRust
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --locked
cargo build --release --locked
./target/release/neoy-core-rust --version
```

Rust owns its compiled tool definitions and help contracts under `fixtures/`.
The test suite covers MCP negotiation, shell/job lifecycle, filesystem/search,
patch, read-only Codex, ChatGPT handoff, PTY process-group cleanup, concurrency,
GUI approval, unlock revocation, and bounded job GC without spawning Node.

`NEO_CORE_FULL_ACCESS_ACK=I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS` (or the matching
private unlock file) is mandatory. An unauthorized child exits without printing
MCP stdout. Child process environments scrub this acknowledgement and tunnel
secrets; stderr is diagnostics only, stdout is JSON-RPC only. Rust has the host
user's permissions, not a restricted filesystem sandbox. Browser control
belongs to Browser Workspace, not Core.

## Native installation and rollback

`mac/NeoY/install-local.sh` builds and tests this crate, codesigns the binary
inside `Neo.app`, and installs the native app through its guarded watchdog.
On launch, NeoY seeds `~/Library/Application Support/NeoY/core/rust/versions/`
from the signed bundle, then activates an immutable version with an atomic
`current` symlink. The active and candidate executables must pass actual MCP
`initialize` and `tools/list` against a scratch data directory. Startup
recovers the last healthy version or bundled signed seed if necessary; a failed
upgrade is rolled back without changing Core job metadata.

The administration surface is `neo setup core status`, `core upgrade bundled`,
`core upgrade /absolute/path/to/signed/neoy-core-rust`, and `core rollback`.
An external candidate must be signed by the same Developer Team. There is no
npm update poll, Node interpreter dependency or switchable Node fallback.

## Private retention

The Rust Core job GC runs hourly, retaining the newest 2,000 completed jobs or
72 hours, whichever preserves more. Each automatic pass removes at most 1,000
verified stale records. It never kills a process, checks live PIDs/process
groups and their start times, and never traverses foreign or symlinked paths.
Unknown ownership fails closed. Existing Core data under `NEO_CORE_DATA_DIR`
is preserved, as are independent Relay job/JEL histories and user media.
