# NeoY macOS runtime

NeoY is NeoX's signed menu-bar/headless-first Mac runtime for native capture/demo, Accessibility/computer-use, phone media/handoff, trusted Mac setup, supervised local processes, and MCP federation.

Architecture work under `mac/NeoY` is governed by
[`docs/design-principles.md`](docs/design-principles.md). That document is the
canonical source for NeoY V2 principles, the Architecture Lens used in planning,
and principle-level review requirements.

## Runtime endpoints

- MCP: configurable local port (default `http://127.0.0.1:6767/mcp`), Bonjour `_mcp._tcp` / `NeoY`
- XChat Harness: `GET /xchat/bootstrap` returns Markdown dynamically composed by the existing `neo bootstrap` CLI from `~/.agents/AGENTS.md`, XChat rules, and `neo skill list`. No MCP Bootstrap Tool is added. On local loopback, use the endpoint directly; remote requests require an authorized `Authorization: Bearer` header (query tokens are not accepted). Responses set `Cache-Control: no-store`. Do not mount/share this private document publicly.
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

Optional/product MCP providers appear as one CLI-style facade per provider (`events` or `mcp.<server>`) and are configured in the control plane. Runtime code is grouped by owner under `Runtime/src/core`: `tools/` owns Core capabilities; `tools/xchat.mjs` is the thin Browser Workspace lifecycle adapter; and `lib/` contains Core helpers. The migrated implementation and MIT attribution are documented in `core/UPSTREAM.md`. MacBridge is not an npm dependency or separate installed service. `~/Workspace/neox/mac/NeoY/Runtime` is the single runtime source of truth: Swift starts the Core stdio provider from that repo directory, while NeoY itself owns the local and public HTTP MCP transport. Runtime source changes require restarting the Core provider; no runtime package copy is installed under Application Support.

NeoY explicitly authorizes only that trusted Core child at spawn time; unrelated stdio providers receive no such authorization. Federation initializes the child, requires a successful `tools/list` before publishing it as ready, routes concurrent JSON-RPC responses by request ID, removes stale registrations on an unexpected exit, and respawns with bounded backoff without restarting NeoY.

Core capabilities use compact CLI-style facades (`shell`, `terminal`, `fs`, `codex`) with exact subcommand schemas available through `command=help`; legacy MacBridge configuration is normalized out of `mcpServers`.

Swift is the signed host, public OAuth/MCP boundary, native capability owner, and MCP federation host. Cloudflare connects directly to NeoY's configured port; the legacy Node gateway/proxy scripts are not launched in the deployed topology.

Control state is schema-versioned and validated. v1 diagnostics-only state migrates explicitly to v2. Malformed state is preserved and surfaced as degraded health rather than silently discarded.

See `docs/neoy-v2-architecture.md` and `docs/neoy-v2-migration-matrix.md`.

## Existing native capabilities

Demo/capture keeps the shared primitive contract and ScreenCaptureKit recording. Accessibility/computer-use stays native because macOS TCC permissions belong to the signed app identity. NeoX phone media discovery/export and phone-to-Mac handoff remain compatible with the existing protocol.

## Ask questions MCP App

`ask_questions` accepts one required Markdown `prompt` string and returns a
private `text/html;profile=mcp-app` widget with safely escaped Markdown, a
multiline answer field, and submit/cancel controls. The app-only companion
tools `ask_questions.submit` and `ask_questions.cancel` use a random session
ID, enforce one submission, and expire unanswered sessions after ten minutes.

The initial tool call completes after registering the session so the MCP Apps
host can render its tool result. In the verified MCP Apps contract,
`ui/message` starts a new conversation turn; it does not resume a completed
tool call. Consequently, the structured answer is returned by
`ask_questions.submit` and sent through `ui/message` as a new turn. NeoY does
not claim same-turn suspension/resumption or hold the gateway request open.

## Tool-call audit

NeoY records metadata for every `tools/call` accepted at its authenticated MCP
gateway in `~/Library/Logs/NeoY/tool-calls.jsonl`. Coverage includes native
tools, bundled Core forwarding, and federated providers. A successful execution
has one `started` and one terminal record; denied, invalid, and unknown tool
requests have one terminal record. Provider results with `isError=true` are
failures. Records contain only time, call ID, tool name, local/remote and
provider provenance, phase/status, terminal duration, and a fixed sanitized
error code; arguments and response bodies are never audited. The private
directory and file modes are `0700` and `0600`. Internal services called
directly without the gateway are outside this audit.

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

The installer uses a valid Apple Development identity and installs `/Applications/Neo.app`. macOS launchd keeps NeoY alive, and NeoY directly owns the `cloudflared` child whenever remote access is enabled. PM2 is not part of the NeoY/tunnel path. Stable signing lets macOS associate one-time TCC grants with `com.neox.neoy` across local rebuilds.

For the supported clean-user source-build, first-run, and private ChatGPT MCP
connection flow, see [Clean Mac install and ChatGPT connection](docs/clean-user-install.md).

An MCP client can point its remote entry at the stable HTTPS endpoint. NeoY's MCP tools are discovered dynamically rather than duplicated in a client manifest.

NeoY can report/open permission settings, but Screen Recording, Accessibility, camera, microphone, notifications, and Local Network remain subject to macOS/user approval.


## NeoY 2.2 Core Agent Runtime

NeoY 2.2 keeps the privileged agent surface intentionally small:

```text
setup                  configuration/control
shell(command,args)     shell and background jobs (@lalalic/neo Core)
fs(command,args)        filesystem read/write/manage (@lalalic/neo Core)
terminal(command,args)  interactive PTY sessions (@lalalic/neo Core)
codex(command,args)     read-only Codex history (@lalalic/neo Core)
apply_file_patch         standard Git unified diff (required cwd) (@lalalic/neo Core)
cluster(command)        trusted neo-node invocation
computer(command,args)  native macOS Computer Use
demo(command,args)      demo recording/annotation
phone(command,args)     paired NeoX phone/media
tour(command,args)      Capture Tours
chatgpt(command,args)     Browser Workspace lifecycle transfer
```

The migrated Core handlers preserve their typed subcommand schemas behind the compact facades; NeoY does not
maintain a duplicate Swift shell/filesystem/PTY/Codex/patch stack. `cluster`
remains NeoY-owned. These Core surfaces are always available on
trusted/local connections. First-party
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
protected-resource and OAuth authorization-server metadata. Authorization uses the
configured Client ID with code + PKCE S256 and returns access/refresh tokens after
the local approval step. During migration NeoY adopts the previous gateway Client ID
and valid token state, so an existing configured `neo` connection continues to work
without rebuilding the connector.

Remote access can use a temporary Cloudflare address or a hostname managed by the
user's Cloudflare account. Own-domain addresses remain stable across restarts;
temporary addresses may change and can require the MCP app to be reconfigured.
Local access always receives every enabled NeoY feature. Remote access is authenticated
and `tools/list`/`tools/call` are filtered by the Features selected in the Remote tab.

## Optional feature contract

NeoY optional products are installed features rather than code compiled into NeoY. A feature is published as a versioned package with `neo-feature.json`, runtime lifecycle scripts, an MCP provider declaration, and setup bootstrap/manual assets. NeoY installs packages under `~/Library/Application Support/NeoY/products/<feature>/`, initializes an instance, and exposes the feature MCP locally. Features that require configuration enter `setup-required` and open a Browser Workspace-backed ChatGPT Temporary Chat using the packaged setup guide. The setup conversation uses the standard `setup feature ...` lifecycle commands instead of feature-specific NeoY code.

Local MCP exposes every enabled feature. Remote access is independent: built-in capabilities and installed MCP providers are explicitly selected on the Remote tab, and newly installed providers default to remote-disabled. `mcp-services` remains only a legacy compatibility identifier and is migrated away from broad remote exposure.

Family Tutor has moved to the Neo monorepo as a local Neo Project and is no longer in the Neo.app Feature catalog. The generic optional-Feature framework remains for other published packages. Retired installed records are not restarted or federated, while their private product files remain untouched.

## MCP Tool Skill dependencies

The native Features screen preserves the 2.3.11 behavior: Tool Feature rows
come from the live local MCP tools/list response, with disabled tools included
so the user can re-enable them. It does not use a fixed Tool Feature list.
markcut.preview belongs to the separate markcut Skill feature, not an
additional Tool Feature row.

Neo.app treats declared Skill dependencies as required when a tool is discovered,
enabled, or invoked. Built-in requirements include chatgpt -> webhelm ->
daemon-service-manage and markcut.preview -> markcut. MCP providers can also
declare them in the tool's _meta.neo.requires.skills array. Neo installs
missing approved Skills through npx skills, verifies the global inventory,
and starts/health-checks WebHelm through the supported uvx webhelm entrypoint.
A temporary bootstrap browser session is closed after setup. Skills requiring
interactive account authorization still need the Setup with Agent action;
installation alone is not proof that authentication succeeded.

Automatic installation accepts only known, approved Skill sources. A user-installed
Skill with another source can satisfy a dependency, but an unknown missing source
is reported rather than fetched from an untrusted MCP declaration. Automatic
Skill updates are opt-in, run daily (checked periodically while the app runs),
and skip unowned/local developer Skills. Neo CLI and clean Git Project auto-updates
have independent opt-in controls. Unclean Projects are never reset or force-pulled.
Native Neo.app upgrades continue to require the signed installer and its rollback
checks.

Neo Project Toolkit shows each first-level Neo Project as an indented checkbox
row, without a collapsible folder. The checkbox persists inclusion in Neo's
project management and automatic updates; it is not a daemon running indicator.
Service lifecycle actions, where available, are in the row's Actions menu.

## Project file mounts

NeoY serves explicitly mounted, read-only project roots under the existing public HTTPS origin:

```bash
node Resources/Scripts/neoy-files.mjs mount vlog /absolute/path/to/vlog
node Resources/Scripts/neoy-files.mjs list
node Resources/Scripts/neoy-files.mjs url /absolute/path/to/vlog/runs/2026-09-27/video.md
node Resources/Scripts/neoy-files.mjs unmount vlog
```

Mount definitions live in `~/Library/Application Support/NeoY/file-mounts.json` and are picked up on each request without restarting NeoY. `GET` and `HEAD /files/<mount>/<relative-path>` support Range requests and cross-origin media loading. Hidden paths and symlinks escaping the mounted root are forbidden. Mounts are **public**, so register only directories that are safe to expose; avoid mounting your home directory, credential stores, or private projects. Local files are never writable over HTTP. The reserved `/_neoy/` export namespace is for generated application assets.

## Service identity

NeoY publishes the logical service ID `neoy/app` under the shared `<skillname>/<service-name>` convention. Its native launchd label remains `com.neox.neoy.keepalive` for existing installations, watchdog rollback, and macOS service continuity. Do not rename the signed bundle identifier or launchd label as part of logical service naming.
