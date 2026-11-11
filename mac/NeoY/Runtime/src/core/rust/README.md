# Native Rust NeoY Core

This is an opt-in development alternative to the stable Node.js Core. It is
**not** installed, packaged, selected by NeoY, or used by any production
provider. The Node.js implementation remains authoritative for deployment.

## Security model

The Rust child uses the same fail-closed startup contract as Node Core:

- startup requires either `NEO_CORE_FULL_ACCESS_ACK=I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS`
  or an unlock file containing that exact acknowledgement;
- the acknowledgement is removed from the process environment before handlers run;
- `CONTROL_PLANE_API_KEY` is scrubbed, and child environments omit both secrets;
- file-backed unlock state is re-read before tool calls and periodically while
  PTY sessions are live; revocation terminates those process groups and exits.
  Environment-ack startup remains authorized for that process lifetime, matching
  Node Core;
- stdout carries JSON-RPC only; startup, security, and diagnostic text goes to stderr;
- the host user retains all normal macOS permissions. The child adds no path sandbox.

## Build and run

From this directory:

```bash
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
cargo build --release

DATA=$(mktemp -d "${TMPDIR:-/tmp}/neoy-rust-core.XXXXXX")
NEO_CORE_DATA_DIR="$DATA" \
NEO_CORE_FULL_ACCESS_ACK=I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS \
  ./target/release/neoy-core-rust
```

Send newline-delimited MCP JSON-RPC on stdin. `initialize`, then
`notifications/initialized`, `tools/list`, and `tools/call` are supported. The
current differential tests compare tool names and schema structure, plus a
set of shell, filesystem-search, patch, Codex, ChatGPT, and PTY examples, when
`NEOY_NODE_CORE` points to `mac/NeoY/Runtime/src/core/tools/index.mjs`:

```bash
NEOY_NODE_CORE=../tools/index.mjs cargo test --test differential -- --nocapture
```

Filesystem search checks `rg` and `fd` on `PATH` or in
`$NEO_CORE_DATA_DIR/tools` (default:
`~/Library/Application Support/NeoY/core/tools`). On supported macOS arm64 and
x86_64 hosts, a missing tool is downloaded from the pinned upstream release,
SHA-256 verified, then safely extracted into the private tools directory.
`NEO_CORE_OFFLINE=1` disables downloads and fails closed when neither binary is
available.

## Architecture

- `gui.rs` owns Node-compatible strict foreground-GUI operator approvals,
  including single-use approval grants before shell execution.
- `context.rs` owns configuration, authorization capture, private storage paths,
  and safe path expansion.
- `jobs.rs` owns durable process-group jobs, output files, status polling,
  signals, and restart-readable metadata. `shell.exec` reports `running` plus a
  durable Job ID when the synchronous wait ends; it never retries the command.
- `pty.rs` owns short-lived in-memory PTY sessions with process groups,
  nonblocking reads, resize, signal, and teardown on transport close, signal, or
  unlock revocation. PTY starts build the complete child environment and argv
  before `fork`, then use `execve` with explicit `envp`; no environment mutation
  happens after fork, so concurrent MCP tool threads cannot hold allocator or
  environment locks into a PTY child. `terminal_session_contract` starts all
  manager PTY slots concurrently while another thread mutates process
  environment state.
- `handlers.rs` owns tool behavior, loopback-only Discord delivery, read-only
  Codex app-server negotiation, Browser Workspace delegation for ChatGPT lifecycle,
  and compact, human-readable terminal outcomes.
- `main.rs` owns line-delimited JSON-RPC framing, negotiation, request
  correlation, bounded concurrent tool calls (32 in flight), structured
  content, protocol errors, and stdout isolation. Like the current Node Core,
  it ignores `notifications/cancelled`; use `shell.job.kill` for supported
  background shell-job cancellation.

Large shell output is captured in a private temporary directory (directory
mode `0700`, file mode `0600`) when it exceeds the inline preview. The caller
receives the preview, full output file path, and total byte count.
Synchronous helper processes retain at most 4 MiB each from stdout and stderr,
matching Node's explicit WebHelm/XChat capture boundary; their pipes continue
draining after the cap, and an oversized response returns `CHILD_OUTPUT_LIMIT`.
PTY sessions retain a bounded circular transcript (256 KiB per session by
default, configurable with `NEO_CORE_PTY_RING_BYTES`); read cursors are absolute
byte offsets and report bytes lost before the retained window.

## Compatibility status

See [`docs/parity-matrix.md`](docs/parity-matrix.md). The head-to-head review
hotfix closes identified differences in filesystem management, shell/PTY
containment, job persistence/metadata, GUI approval, modern MCP framing and
status fields, backed by new focused differential regression tests. A passing
suite is not proof of complete behavioral identity over every possible input.
This alternative is **not activated in NeoY**; retain Node as production until
a separately authorized, independently reviewed Swift federation canary and
rollback verification succeed.

## Local NeoY canary / rollback

A signed NeoY host with `core provider` support can select this independently
installed binary. Copy the reviewed release binary to the private path
`~/Library/Application Support/NeoY/core/rust/neoy-core-rust` (0700 directory,
0700 executable), then use `neoy.setup` with `core provider rust`; the native
runtime reconnects the `core` stdio provider without restarting NeoY. Check
`core status` and `status`/`shell.exec` MCP behavior, not only the selection
receipt. `core provider node` immediately selects the managed Node runtime
again. The Core binary itself does not publish or manage WebHelm sessions.
