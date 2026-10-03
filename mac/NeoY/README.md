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

Optional/product MCP tools appear as `mcp.<server>.<tool>` and are configured in the control plane. MacBridge is different: it is a dependency of the published `@lalalic/neo` package and is pinned there from upstream `alexanderradahl/mac-developer-bridge`. `runtime.json` selects the required `@lalalic/neo` version; `bootstrap-runtime.sh` installs it with npm under `~/Library/Application Support/NeoY/runtime/node_modules/@lalalic/neo` and atomically replaces the runtime when that version changes. Swift auto-registers the installed MacBridge provider at startup.

For local runtime development, `~/Library/Application Support/NeoY/runtime-source` may contain an absolute path to a runtime source checkout (normally `.../mac/NeoY/Runtime`). `runtime-control.sh` uses that source for the gateway/proxy scripts while keeping npm-installed dependencies and the production version pin intact. Remove the file to return immediately to the installed npm runtime. Its tools keep their original names (`shell_exec`, `pty_start`, `fs_read`, etc.) instead of an `mcp.macbridge.*` wrapper, and MacBridge is not persisted in `mcpServers`.

The Node.js runtime package owns the Web ChatGPT gateway/proxy scripts and direct Node dependencies. Swift remains the signed host, public auth boundary, native capability owner, and MCP federation host.

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
cluster(command)          trusted neo-node invocation
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

Remote Macs are `neo-node`s and do not need NeoY installed, but they do need a Node.js executable. The normal bootstrap
contract is `cluster add <name> --ssh <user>@<host>[#port=<port>]`; port 22 is the
default. NeoY connects over that SSH endpoint, copies its bundled single-file Node.js `neo-node.mjs` runtime,
starts the node MCP runtime, establishes the node-to-NeoY MCP tunnel, verifies it, and
registers the node. For an outbound-only Mac, the user first creates an SSH reverse
tunnel that exposes the Mac's SSH port on the NeoY machine, then calls the same command
with that loopback endpoint, for example `cluster add work --ssh chengli@127.0.0.1#port=22022`.
Reverse-SSH bootstrap uses the session lifecycle, so it does not require LaunchAgent;
the mini runtime supervisor maintains its own reverse MCP tunnel after bootstrap.
`cluster pair` remains the low-level operation for an already-running MCP endpoint, and
`cluster invoke` exposes the canonical `exec` / `fs` contract while adapting to the node
transport. NeoY-to-NeoY peers are supported separately as `neoy-peer`.

### MCP setup

The Setup window has three tabs: **MCP**, **Remote**, and **Advanced**. MCP shows
the local endpoint, editable service port (default **6767**), and the client ID/token
needed to create an MCP app connection. The token can be revoked/rotated at any time;
rotation invalidates the previous token while preserving the client ID.

For Web ChatGPT, create the MCP App with the display name **`neo`** and point it at
the public **`https://<host>/mcp`** endpoint. The public endpoint publishes MCP
protected-resource and OAuth authorization-server metadata, including an RFC 7591
dynamic-client-registration endpoint, so Web ChatGPT can obtain its own public
`client_id` without a copied client secret. Authorization uses code + PKCE S256 and
returns access/refresh tokens after the local approval step. The Client ID shown by
NeoY remains supported for existing/manual connections. Keep the existing legacy
NeoY/Mac Bridge connection installed while migration/E2E verification is still in
progress.

Remote access can use a temporary Cloudflare address or a hostname managed by the
user's Cloudflare account. Own-domain addresses remain stable across restarts;
temporary addresses may change and can require the MCP app to be reconfigured.
Local access always receives every enabled NeoY feature. Remote access is authenticated
and `tools/list`/`tools/call` are filtered by the Features selected in the Remote tab.

## Optional feature contract

NeoY optional products are installed features rather than code compiled into NeoY. A feature is published as a versioned package with `neo-feature.json`, runtime lifecycle scripts, an MCP provider declaration, and setup bootstrap/manual assets. NeoY installs packages under `~/Library/Application Support/NeoY/products/<feature>/`, initializes an instance, and exposes the feature MCP locally. Features that require configuration enter `setup-required` and open a Browser Workspace-backed ChatGPT Temporary Chat using the packaged setup guide. The setup conversation uses the standard `setup feature ...` lifecycle commands instead of feature-specific NeoY code.

Local MCP exposes every enabled feature. Remote access is independent: built-in capabilities and installed MCP providers are explicitly selected on the Remote tab, and newly installed providers default to remote-disabled. `mcp-services` remains only a legacy compatibility identifier and is migrated away from broad remote exposure.

Family Tutor is the first feature using this contract. Family Tutor itself owns Browser Workspace, learner Project/thread bindings, Discord/Cloudflare integration, and tutoring runtime; NeoY owns only installation, lifecycle, setup orchestration, MCP federation, and remote exposure policy.
