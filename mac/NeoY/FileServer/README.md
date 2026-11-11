# NeoY Rust File Server (private sidecar)

This is an **unprivileged-in-purpose, loopback-only** HTTP file-serving sidecar.
The NeoY Swift gateway still owns public URLs, tunnel/credentials, mount and
unmount commands, and the native application lifecycle. No MCP tools are added.
Unlike unrestricted Rust Core, this helper has no shell or filesystem write API.

The sidecar uses **Actix Web + `actix-files::NamedFile`** for streaming, ranges,
conditional caching and MIME handling. `cap-std` opens a capability-confined
file descriptor first; `NamedFile::from_file` serves that already opened handle,
preventing pathname replacement races and symlink escape. The helper listens
only on a randomly chosen localhost port and requires a per-launch token sent
solely by NeoY's reverse proxy. It exits when its parent disappears.

Mounted files retain `/files/<mount>/<relative>`; the old `/files/...` and
`/public/...` static-root routes remain supported. For
`/preview-files/<mount>/<relative>`, `vision-normalized-manifest.json` selects an
existing `.normalized` proxy or falls back to the original media. All mounts
are dynamically re-read from NeoY's existing `file-mounts.json` configuration.
Direct user URLs and `video.md` content never change.

On sidecar connection failure **before any response bytes**, the gateway uses
the original Swift file handler. Responses that have started streaming are
never restarted or duplicated. The Swift listener maintains 64 KiB bounded
backpressure, and no downloaded media is buffered in memory.

## Build and verify

```bash
cargo test --locked --manifest-path mac/NeoY/FileServer/Cargo.toml
cargo clippy --locked --manifest-path mac/NeoY/FileServer/Cargo.toml --all-targets -- -D warnings
cargo build --locked --release --manifest-path mac/NeoY/FileServer/Cargo.toml
```

The **canonical** `mac/NeoY/install-local.sh` builds, signs, and packages the
Rust binary as `Contents/Resources/neoy-file-server` inside Neo.app; do not
replace the installed bundle manually. The runtime is started and stopped by
NeoY's `MCPServer`. No PM2 or extra external port is required.

Security tests cover traversal, encoded hidden segments, outside-root symlinks,
unauthorized loopback access, Range/416, HEAD, ETag/304, normalized proxy and
fallback. Validate real HTTP/seek playback against the Swift gateway before
retiring the fallback.

For immediate local rollback, launch NeoY with `NEOY_FILE_SERVER_BACKEND=swift`;
this disables the helper while retaining the original Swift file-serving route.
The switch is evaluated at server startup. A crashed/unreachable helper falls
back automatically without changing public URLs.
