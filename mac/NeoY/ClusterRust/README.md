# Native Rust Neo Cluster Node

This **separate remote Mac runtime** replaces `neo-node.mjs` without requiring Node.js or NeoY on remote hosts. The Swift `cluster` control plane, SSH bootstrap, seven MCP tools, `cluster invoke` contract, and configured reverse-tunnel URLs remain stable. It is intentionally independent of NeoY Core and does not expose a second public-facing listener.

`neo-cluster-rust` implements `install|run|serve|start|stop|restart|status|doctor|uninstall-persistence|--version`. The single `run` process owns the loopback MCP listener and supervises the outbound `ssh -R` tunnel with reconnect backoff. Persistent nodes use macOS LaunchAgent `com.neo.node.<name>`; outbound-only nodes use a detached session process. Cluster bootstrapping copies a pre-signed universal binary, verifies architecture/version, stages a previous binary and config for rollback, and pairs the existing MCP endpoint.

`/healthz` and HTTP JSON-RPC `/mcp` retain the old seven tool names: `shell_exec`, `fs_read`, `fs_write`, `fs_list`, `process_list`, `shell_start`, `shell_poll`. Tools are available **only through 127.0.0.1** and the existing SSH reverse tunnel. Remote node commands run under the authenticated OS account used for SSH, without any new privilege elevation. The existing Swift gateway remains the trust boundary.

Shell commands use isolated OS process groups; timeout sends TERM then KILL. I/O limits are 4 MiB per stream, and asynchronous sessions are tracked in the single Rust service. `shell_exec.timedOut` now reports true on actual timeout, fixing the old Node false-negative. Remote CLI and HTTP compatibility tests should run against **both** supported Mac architectures and an actual node via `cluster invoke`.

```sh
cargo test --locked --manifest-path mac/NeoY/ClusterRust/Cargo.toml
cargo clippy --locked --manifest-path mac/NeoY/ClusterRust/Cargo.toml --all-targets -- -D warnings
```

`mac/NeoY/install-local.sh` and `.github/workflows/neo-macos-release.yml` build/sign/package the universal `neo-cluster-rust` binary under `Neo.app/Contents/Resources`. Do not install an unsigned runtime over an authorized signed one. The `cluster add` command is the supported migration and rollback entry point. Do not remove old remote runtimes until a verified successful Rust tunnel and MCP handshake.

## Crash recovery and MCP request safety

Unclean supervisor death may leave an outbound SSH child alive. On startup,
ClusterRust inspects the previous tunnel PID and verifies its exact SSH command,
reverse-forward ports, and hub destination before terminating that orphan.
Unrelated or recycled PIDs are never signaled. Short and long-running shell
commands are grouped and terminated on cancellation/shutdown; child output is
bounded. Local MCP commands accept only JSON requests without a browser Origin
header, preventing cross-origin form/no-CORS requests from issuing shell tools.
Potentially slow file operations run outside the HTTP event loop.
