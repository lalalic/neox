# NeoY macOS companion

NeoY is NeoX's native menu-bar companion for Mac Capture Tour, demo automation, focused Accessibility/computer-use actions, phone media access, and phone-to-Mac agent handoff.

## Runtime endpoints

- MCP: `http://127.0.0.1:9224/mcp`, Bonjour `_mcp._tcp` / `NeoY`
- Phone handoff: TCP `8686`, Bonjour `_neoy._tcp`, `POST /agent`
- Handoff queue: `GET /agent/peek`, `GET /agent/next?timeout=0..30`
- Handoff persistence: `~/.neoy/inbox`
- Local exports: `~/Library/Application Support/NeoY/exports`
- Setup/control: MCP tool `neoy.setup` with `help`, `help overview|status|roadmap`, and read-only `status`.

NeoY replaces both the old **Neox Tour** Mac app and the standalone Python `neoy-bridge.py` service. Only NeoY should own ports 9224 and 8686.

The NeoY v2 capability audit and phased architecture are documented in `docs/neoy-v2-migration-matrix.md` and `docs/neoy-v2-architecture.md`.

## Demo runtime

The Mac binding follows `~/Workspace/demo/contracts/primitives.md` and exposes:

`demo.start_recording`, `demo.step`, `demo.spotlight`, `demo.annotate`, `demo.caption`, `demo.say`, `demo.cursor`, `demo.highlight`, `demo.clear`, `demo.pause`, `demo.resume`, `demo.wait`, and `demo.stop_recording`.

The runtime records H.264 MOV output with ScreenCaptureKit and writes a semantic `.events.json` sidecar. Screen Recording permission is required for real capture.

UI actions stay separate from visual primitives: `accessibility.inspect`, `accessibility.resolve`, `computer.click`, `computer.type`, `computer.set_value`, `computer.key`, `computer.scroll`, and `computer.drag`. Semantic inspection/actions require macOS Accessibility permission.

## NeoX phone media

NeoY discovers NeoX on `_mcp._tcp` or accepts the exact MCP URL embedded in a phone handoff. It exposes `phone.status`, `phone.media.search`, `phone.media.meta`, `phone.media.thumbnail`, and `phone.media.export`. Exports are downloaded to `~/Library/Application Support/NeoY/exports/phone/`; indexing remains authoritative on the phone.

## Build and test

```bash
cd mac/NeoY
xcodegen generate
xcodebuild -project NeoY.xcodeproj -scheme NeoY -configuration Debug build
xcodebuild -project NeoY.xcodeproj -scheme NeoY -configuration Debug test
```

For iterative local installs, prefer:

```bash
./install-local.sh
```

The helper builds NeoY, discovers a valid local **Apple Development** signing identity, re-signs the app with that stable identity, installs it at `/Applications/NeoY.app`, and registers `com.neox.neoy.keepalive` as a per-user LaunchAgent (`RunAtLoad + KeepAlive`). If NeoY is missing or crashes, launchd recreates it automatically. This avoids ad-hoc signatures whose designated requirement is only a changing CDHash; with the stable identity, Screen Recording and Accessibility authorization can survive rebuilds after the one-time grant.

Run `NeoY.app` as an app bundle so macOS can associate Screen Recording, Accessibility, and Local Network permissions with `com.neox.neoy`.
