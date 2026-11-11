# Rust Core parity matrix

The compatibility authority is the current Node Core under `../tools/` and its
Runtime tests. The Rust crate is an opt-in development alternative; this matrix
records only behavior exercised by the current Rust differential E2E tests.
It does **not** claim full tool or lifecycle parity.

| Contract area | Evidence | Status / remaining gap |
| --- | --- | --- |
| Startup and stdio | `unauthorized_startup_writes_no_stdout`; `file_unlock_revocation_terminates_child`; initialized legacy MCP requests | Environment acknowledgement startup, file-backed unlock/revocation, and JSON-RPC-only stdout are checked. Malformed protocol behavior is not fully differential-tested. |
| Tool inventory, schemas and help | `mcp_inventory_and_representative_calls` compares complete Node/Rust tool objects and help responses for all six facades; `command_facades_reject_unknown_nested_commands_and_invalid_arguments` checks unknown nested commands and malformed arguments | Fixtures must be refreshed from the same Node source before release review. The tests cover the current exposed commands and key rejection boundaries, not every malformed-input permutation. |
| Shell execution | Representative `shell.exec`, caller stdin, secret-variable scrubbing, bounded preview/private output file, timeout termination; `background_job_metadata_survives_core_restart` verifies reading and killing a persisted job after a Core restart | Reviewed Node job metadata, GUI approval, and output overflow copying now have regression coverage below. MCP cancellation remains ignored by both providers; broader lifecycle combinations are not exhaustively covered. |
| Synchronous helper subprocesses | `handlers::tests::child_output_is_drained_concurrently_and_timeout_kills_group` verifies concurrent draining, timeout termination, and cleanup of TERM-ignoring descendants; `child_output_capture_is_bounded_and_drains_overflow` accepts 4 MiB and rejects byte 4 MiB + 1 | Retains at most 4 MiB per stream, matching Node's explicit WebHelm/XChat `maxBuffer`; excess is drained and returns `CHILD_OUTPUT_LIMIT`. Node Codex app-server lines are independently bounded at 8 MiB. |
| Filesystem and patch | `filesystem_and_patch_contracts` verifies atomic replacement, requested mode, append, create-parent rejection, byte/line reads, recursive hidden-aware listing, bounds, metadata, invalid patch, glob filtering, `.gitignore`, invalid glob errors, and nested `rg`/`fd` calls | Search checks executable versions, honors `NEO_CORE_OFFLINE=1`, and on supported macOS architectures downloads pinned Node-compatible releases only after SHA-256 verification; archive paths are checked before extraction. `handlers::tests::search_tool_manifest_and_archive_checksum_are_verified` checks the manifest/checksum implementation. |
| PTY | `terminal_session_contract`, `pty_cursor_ring_and_text_normalization_match_contract`, `idle_pty_session_is_reclaimed`, and `pty_max_lifetime_expires_even_when_session_is_read` cover cursor/read options, ring loss reporting, ANSI/CR normalization, resize readback, idle/lifetime expiry, canonical input limits and cleanup. `file_unlock_revocation_terminates_child` revokes access during a running process. | Retention defaults to 256 KiB per session (configurable from 4 KiB to 4 MB), matching Node. Cursors are absolute byte offsets and read results report lost and retained bytes. |
| Codex, Discord, ChatGPT | Tool names/schemas compare with Node fixtures. Codex fake app-server checks coalesced lines and child cleanup. ChatGPT fake CLI covers accepted/rejected receipts, provider exit errors, durable thread identity and private config modes. Discord checks loopback-only rejection. | External CLI session/provider behavior is not a Core responsibility. Compatibility checks cover subprocess invocation, machine-readable receipts, timeout/errors and secrets handling using a fake CLI; live provider E2E is intentionally not a Rust Core acceptance gate. |
| Concurrency and cancellation | `concurrent_calls_keep_response_ids_correlated` (sends `notifications/cancelled` while the slow call is running) | Tool calls execute concurrently up to 32 in-flight requests, and responses retain their JSON-RPC IDs. Both current Node and Rust ignore MCP cancellation notifications, so cancellation does not stop in-flight operations; explicit shell job cancellation remains available through `shell.job.kill`. |

## Code-to-code parity hotfix (November 2026)

The Node Core remains the compatibility reference and the only live provider.
The source-comparison review identified runtime differences that schema fixtures
alone could not expose; this hotfix addresses them with dedicated tests:

| Reviewed boundary | Corrective change | Executable evidence |
| --- | --- | --- |
| Core exit / transport close | SIGTERM, SIGINT, and stdin EOF reclaim PTY and active helper groups; unlock revocation exits 78 (matching Node) | `disconnect_and_sigterm_reclaim_terminal_process_group`, `file_unlock_revocation_terminates_child`, `unlock_revocation_racing_foreground_shell_reclaims_child_group` |
| `fs.manage` | Recursive/force/mode, directory copying, relative symlinks, cross-filesystem moves, chmod validation, copy safety | `filesystem_manage_preserves_node_permissions_and_tree_contract` |
| GUI safety | `strictApprovals` and one-use foreground approval before `shell.exec` and `shell.start` | `strict_gui_approval_blocks_shell_exec_and_start`, `gui_approval_is_single_use_and_accepts_node_grant_format` |
| Shell jobs | Node `id`, ISO dates, signal names, legacy Rust metadata compatibility, Node-created record consumption, private overflow snapshots | `rust_reads_existing_node_job_metadata_without_migration`, `background_job_metadata_survives_core_restart`, `shell_exec_stdin_output_limit_and_timeout` |
| PTY containment | SIGTERM/EOF reclaim, start-time-qualified cleanup, and independent `waitpid` reaping after Darwin PTY EIO/EOF (0.2.1) | `detached_terminal_process_is_reclaimed_on_close`, `disconnect_and_sigterm_reclaim_terminal_process_group`, `short_lived_pty_preserves_output_and_reaps_exit_status`, `pty_fork_survives_concurrent_shell_and_fs_calls` |
| MCP and status | Modern protocol `_meta` key, request validation/error shape, existing host status fields, PTY availability, patch errors | `core_status_and_mcp_boundary_match_node_contract`, `modern_protocol_returns_completion_metadata`, `mcp_inventory_and_representative_calls` |

**Remaining limitations:** The tests cover the reviewed code differences and
representative Node/Rust differential behavior, not all possible argument
combinations, filesystem device boundaries, process races, or authorization
states. Status values that intrinsically differ by runtime (for example the
Node.js version) cannot be byte-identical. Both providers ignore
`notifications/cancelled`; explicit shell-job cancellation works. External
CLI providers (including WebHelm/ChatGPT) are separate from this Core parity
contract; only CLI execution, exit codes, stdout/stderr and process handling
belong to Core. An actual opt-in Rust child through the Swift federation host
still requires a separate authorized canary before production cutover.

The tool inventory/schema differential runs when `NEOY_NODE_CORE` points to
the Node entry point. From this crate run:

```sh
NEOY_NODE_CORE=../tools/index.mjs cargo test --locked
cargo fmt --check
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo build --locked --release
```

The Rust crate remains an independently runnable **opt-in development
alternative**, not selected by NeoY. Production Node Core is unchanged.
