# NeoY macOS runtime

NeoY is NeoX's signed menu-bar/headless-first Mac runtime for native capture/demo, Accessibility/computer-use, phone media/handoff, trusted Mac setup, supervised local processes, and MCP federation.

## Runtime endpoints

- MCP: `http://127.0.0.1:9224/mcp`, Bonjour `_mcp._tcp` / `NeoY`
- Phone handoff: TCP `8686`, Bonjour `_neoy._tcp`, `POST /agent`
- Handoff queue: `GET /agent/peek`, `GET /agent/next?timeout=0..30`
- Handoff persistence: `~/.neoy/inbox`
- Local exports: `~/Library/Application Support/NeoY/exports`

NeoY replaces the old Neox Tour Mac app and standalone Python `neoy-bridge.py`. Only NeoY should own ports 9224 and 8686.

## One setup surface

Agent-facing runtime configuration is intentionally concentrated in one MCP tool:

```text
neoy.setup(command: String?)
```

Run `help` or `help <topic>` at runtime for the authoritative command grammar. v2 covers status/config, diagnostics, native permission guidance, managed startup processes, configured HTTP MCP federation, and important NeoX event policy/delivery.

Configured remote MCP tools appear as `mcp.<server>.<tool>`. Local MCP servers can be started by the startup supervisor and then federated by URL.

Control state is schema-versioned and validated. v1 diagnostics-only state migrates explicitly to v2. Malformed state is preserved and surfaced as degraded health rather than silently discarded.

See `docs/neoy-v2-architecture.md` and `docs/neoy-v2-migration-matrix.md`.

## Existing native capabilities

Demo/capture keeps the shared primitive contract and ScreenCaptureKit recording. Accessibility/computer-use stays native because macOS TCC permissions belong to the signed app identity. NeoX phone media discovery/export and phone-to-Mac handoff remain compatible with the existing protocol.

## Build and test

```bash
cd mac/NeoY
xcodegen generate
xcodebuild -project NeoY.xcodeproj -scheme NeoY -configuration Debug test CODE_SIGNING_ALLOWED=NO
```

NeoX compatibility build:

```bash
cd ../..
xcodegen generate
xcodebuild -project Neox.xcodeproj -scheme NeoxApp -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

For a real Mac installed-app E2E:

```bash
cd mac/NeoY
./install-local.sh
```

The installer uses a valid Apple Development identity, installs `/Applications/NeoY.app`, and keeps it alive via the per-user `com.neox.neoy.keepalive` LaunchAgent. Stable signing lets macOS associate one-time TCC grants with `com.neox.neoy` across local rebuilds.

NeoY can report/open permission settings, but Screen Recording, Accessibility, camera, microphone, notifications, and Local Network remain subject to macOS/user approval.
