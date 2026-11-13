# Rust-only Core retirement — implementation and verification

Architecture lens: [design-principles.md](design-principles.md).

- **Native necessity:** NeoY signs and supervises Core; generic shell/fs/PTY,
  Codex and background jobs belong to the independently launched Rust child.
- **Source of truth:** `CoreRust` owns all MCP tool contracts and private Core
  job metadata. No Node Core implementation, npm package or Node fallback.
- **MCP intent and trust:** `shell`, `fs`, `terminal`, `codex`, `apply_file_patch`
  retain existing names/schema and the single authenticated NeoY gateway.
  No new public MCP primitive or unauthenticated network endpoint.
- **State and lifecycle:** Existing `NEO_CORE_DATA_DIR` and job history stay put.
  Versioned managed Rust Core selects immutable signed binaries atomically.
  New bundled versions are probed before promotion; previous healthy signed
  release or signed app seed recovers damaged installations. Only explicit
  administrator requests can install a separate same-team signed executable.
- **Submission vs completion:** Installer stage success is not considered live
  until signed app, launchd, MCP `initialize/tools/list`, Core tool invocation,
  and watchdog health all pass; restoring the previous app is failure recovery.
- **Deployment:** PM2 and app signing remain infrastructure, not part of Core's
  public contract. Independent Node services are untouched.

Verification gates: Rust fmt/clippy/test/release, Swift XCTest native manager
(restart, corrupt version, explicit upgrade, rollback), native file server
suite, source-build with signed dual Rust helpers, deployed MCP and watchdog.
The Node Core npm publish workflow is removed; macOS release CI builds and
signs universal native Rust Core and FileServer children.
