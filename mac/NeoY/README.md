# NeoY macOS runtime

NeoY is NeoX's signed menu-bar/headless-first Mac runtime for native capture/demo, Accessibility/computer-use, phone media/handoff, trusted Mac setup, supervised local processes, and MCP federation.

## Runtime endpoints

- MCP: configurable local port (default `http://127.0.0.1:9224/mcp`), Bonjour `_mcp._tcp` / `NeoY`
- Public MCP: optional Cloudflare Temporary tunnel or named-domain tunnel; the Setup window can start, stop, and test either mode
- Phone handoff: TCP `8686`, Bonjour `_neoy._tcp`, `POST /agent`
- Handoff queue: `GET /agent/peek`, `GET /agent/next?timeout=0..30`
- Handoff persistence: `~/.neoy/inbox`
- Local exports: `~/Library/Application Support/NeoY/exports`

NeoY replaces the old Neox Tour Mac app and standalone Python `neoy-bridge.py`.

## One setup surface

Agent-facing runtime configuration is intentionally concentrated in one MCP tool:

```text
neoy.setup(command: String?)
```

Run `help` or `help <topic>` at runtime for the authoritative command grammar. Deployment values use the same model as the Setup window:

```text
deployment show
deployment set port <1...65535>
deployment set tunnel <off|quick|named>
deployment set tunnel-name <name>
deployment set hostname <host>
```

Changing deployment settings persists them, restarts the MCP listener after the current response completes, and reconciles the Cloudflare tunnel. The menu-bar **Setup…** window exposes the same port/tunnel values plus local/public test buttons and MCP app credentials.

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

The installer uses a valid Apple Development identity and installs `/Applications/NeoY.app`. When PM2 is available it becomes the primary supervisor for `neoy` (and `neoy-tunnel` when enabled); the legacy per-user LaunchAgent is only a fallback. PM2 state is saved so runtime/tunnel services survive daemon resurrection. Stable signing lets macOS associate one-time TCC grants with `com.neox.neoy` across local rebuilds.

An MCP client can point its remote entry at the stable HTTPS endpoint. NeoY's MCP tools are discovered dynamically rather than duplicated in a client manifest.

NeoY can report/open permission settings, but Screen Recording, Accessibility, camera, microphone, notifications, and Local Network remain subject to macOS/user approval.


## NeoY 2.2 Core Agent Runtime

NeoY 2.2 keeps the privileged agent surface intentionally small:

```text
neoy.setup(command)    configuration/control
mac.exec(command)      shell, background jobs, PTY
mac.fs(command)        filesystem read/write/manage
codex.threads(command) read-only Codex history
node(command)          trusted remote NeoY Core invocation
```

Each tool documents its current grammar through `command=help`. The five Core
surfaces are always available on trusted/local connections. First-party
specialized capabilities remain enabled by default but can be hidden at runtime
with `neoy.setup("capability disable <name>")`.

Core tools are privileged. Direct loopback MCP calls are trusted. Requests
arriving through the public Cloudflare tunnel do not see or invoke Core tools
unless they carry the NeoY Core token. `neoy.setup("auth show")` returns the
trusted Core URL for an already-trusted local agent; treat that URL/token as a
secret.

Remote Macs run NeoY too. `node discover` browses `_mcp._tcp`, `node pair`
stores an explicit trusted peer, and `node invoke` forwards one of the same
canonical Core tools rather than maintaining per-node wrapper tools.

### MCP setup

The Setup window has three tabs: **MCP**, **Remote**, and **Advanced**. MCP shows
the local endpoint, editable service port (default **6767**), and the client ID/token
needed to create an MCP app connection. The token can be revoked/rotated at any time;
rotation invalidates the previous token while preserving the client ID.

Remote access can use a temporary Cloudflare address or a hostname managed by the
user's Cloudflare account. Own-domain addresses remain stable across restarts;
temporary addresses may change and can require the MCP app to be reconfigured.
Local access always receives every enabled NeoY feature. Remote access is authenticated
and `tools/list`/`tools/call` are filtered by the Features selected in the Remote tab.
