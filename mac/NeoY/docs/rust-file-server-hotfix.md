# Rust File Server Architecture Lens / Hotfix

This plan follows `docs/design-principles.md`.

- **Native necessity / owner**: file transfer does not need Swift UI/TCC; a
  private Rust sidecar owns streaming. Swift NeoY continues to own external
  listener, authenticated MCP traffic, public mount policy and app lifecycle.
- **Surface/trust**: no new MCP tool, URL or external port. An isolated loopback
  helper requires a random per-process token; Swift is the only forwarding
  endpoint. Browser, mobile and Markcut still use existing links.
- **Lifecycle**: Swift launches on listener startup, stops on shutdown; Rust
  exits if its parent dies. A missing/broken child falls back to the prior Swift
  implementation. Streaming success is not asserted merely from launching.
- **Security**: only explicit read-only mounts; secure capability-relative
  open with `cap-std`, no symlink escapes; `actix-files` streams the already-open
  file handle. No shell, Core full-access authorization or PM2 dependency.
- **Product/platform**: preview mapping is a file-server policy reading the
  Visioner manifest; no Markcut document rewriting or business IDs are stored.
- **Harness/Projects**: mounts stay user-owned and outside runtime source; no
  work is performed under a specific project's private `runs` by default.

**Verification criteria**: Rust unit tests; Swift build and tests; signed
one-time canonical install; localhost HTTP Range, ETag, HEAD, preview fallback,
path security and concurrent transfers; fallback when helper absent; Git
merge, live verification and cleanup. Do not claim benchmark improvements
without measured Swift/Rust throughput comparisons.
