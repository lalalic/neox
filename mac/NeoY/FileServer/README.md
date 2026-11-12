# NeoY Rust File Server (private sidecar)

This is an **unprivileged-in-purpose, loopback-only** HTTP file-serving sidecar.
The NeoY Swift gateway still owns public URLs, tunnel/credentials, mount and
unmount commands, and the native application lifecycle. No MCP tools are added.
Unlike unrestricted Rust Core, this helper exposes no shell or filesystem write API.
Its only writes are private, derived preview media in `preview-media-cache` next to
NeoY's `file-mounts.json`; mounted source media is never modified.

The sidecar uses **Actix Web + `actix-files::NamedFile`** for streaming, ranges,
conditional caching and MIME handling. `cap-std` opens a capability-confined
file descriptor first; `NamedFile::from_file` serves that already opened handle,
preventing pathname replacement races and symlink escape. The helper listens
only on a randomly chosen localhost port and requires a per-launch token sent
solely by NeoY's reverse proxy. It exits when its parent disappears.

Mounted files retain `/files/<mount>/<relative>`; the old `/files/...` and
`/public/...` static-root routes remain supported. Markcut-generated video snapshots
also use `/preview-files/_neoy/markcut/generated/<revision>/<file>.mp4`, strictly
scoped to that existing public export directory. This closes the bypass where
Markcut historically served generated movie assets as full-sized `/files/_neoy/…`
media; other `_neoy` preview paths remain denied. For
`/preview-files/<mount>/<relative>`, `vision-normalized-manifest.json` selects an
existing `.normalized` proxy only when it is timeline-faithful (`sampled` is
false) and covers exactly the requested media. Entries can optionally include
`startSeconds` and `durationSeconds` to identify a pre-generated clip. The
internal preview URL accepts the same two query parameters to request a
frame-accurate time slice of a larger source. If no matching proxy exists,
FFmpeg generates a cached, mobile-sized H.264/AAC proxy, preserving the full
original or exactly the requested time interval. Conversion failure falls back
to the original for whole-file requests; explicit time slices return 503 rather
than silently using the wrong part of a video. The existing Swift file-serving
fallback remains for regular whole-file requests. All mounts
are dynamically re-read from NeoY's existing `file-mounts.json` configuration.
Preview responses send `Cache-Control: no-store`; Markcut supplies a
source-versioned `pv` query key (16 hexadecimal digits) so previously cached
Cloudflare responses cannot shadow a new proxy. The server validates but
otherwise ignores that key. Direct original file URLs and `video.md` content never change. Preview
requests use `/preview-files/` only; `/files/` always serves originals.

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
