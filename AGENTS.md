# AGENTS.md — machine-room notes for working on Neox

Instructions for coding agents (and humans) modifying this repo.

## What this is

`Neox` — a headless iPhone app that serves the phone's photo/video library to
desktop agents over MCP. One app target, zero external SPM dependencies,
27 tracked files (18 Swift). Source of truth for behavior: `Neox/Server/`.

## NeoY v2 architecture rules

These are architectural constraints, not implementation suggestions. New Mac-side
work should be reviewed against them before adding code to `mac/NeoY`.

- **NeoY is the authenticated external MCP gateway plus native/TCC capability
  host.** Keep one public auth boundary at NeoY. Do not make every federated
  service independently public or independently authenticated just because it is
  reachable through NeoY. Trusted provider MCPs should bind to loopback unless
  there is a separate product requirement for public access.
- **Default to federation.** Before implementing a new tool in NeoY, ask whether
  an existing service/runtime already owns that capability. If it does, register
  or discover that MCP provider and federate it. Do not copy its implementation
  into NeoY. A core provider may be a version-pinned dependency of
  `mac/NeoY/Runtime/package.json` and bundled inside `NeoY.app`; do not put such a
  core provider in mutable user control-plane state. Provider registration/discovery
  errors must be caught and isolated; an optional provider must never make the NeoY
  app fail to launch.
- **Native NeoY code is reserved for capabilities that need the NeoY process or
  macOS privileges.** Typical examples are Accessibility/Screen Recording/TCC
  computer use, capture/demo/tour UI, direct local device control, and app
  lifecycle integration. Generic workflow engines, browser platforms, tutoring,
  posting, event services, and similar product logic belong outside NeoY.
- **Browser Workspace owns the browser.** Never add ChatGPT-specific URLs, DOM
  selectors, tab grouping, target reuse, Chrome state, or site-specific submit
  logic to NeoY. Use Browser Workspace platform contracts instead. If a caller
  needs a long-lived tab/session, the caller owns that session lifecycle and
  passes the session handle to the platform action. The action itself must remain
  submission-oriented and must not grow a `persistent` business semantic.
- **Persist stable business identity, not UI identity.** Product runtimes may store
  IDs such as `project_id`, `thread_id`, child/user IDs, correlation IDs, and
  explicit workflow state. Do not persist canonicalized page URLs, DOM selectors,
  Chrome target IDs, or other platform internals as product state when stable IDs
  exist. The platform reconstructs URLs and UI state from stable IDs.
- **Separate submit acknowledgement from final completion.** A synchronous MCP
  ingress that kicks off ChatGPT/browser work should return after the platform has
  verified that the turn was accepted. It must not hold the request open waiting
  for the assistant/web page to finish. The eventual answer must come back through
  an explicit tool/event/callback contract keyed by an opaque correlation ID.
- **Do not scrape a result when the result can be delivered.** Prefer the remote
  agent/model actively calling a narrow result-delivery tool (or emitting a typed
  event) over polling assistant DOM text. DOM completion scraping is a platform
  fallback/debug technique, not the product protocol.
- **Keep external ownership visible in names.** Optional/product federated tools
  remain namespaced as `mcp.<provider>.*`. Bundled core Node runtime dependencies
  are part of NeoY's core surface and preserve their original tool names; do not
  wrap MacBridge core tools in `mcp.macbridge.*`.
- **Thin gateway, explicit contracts.** Authentication, authorization, provider
  federation, native privileged capabilities, and routing belong at the gateway.
  Product rules, workflow state, platform automation, and delivery semantics stay
  with their owning service. Prefer small typed contracts between those layers to
  shared code or hidden cross-repo dependencies.

Decision rule for any proposed NeoY v2 feature:

```text
Does it require NeoY's process, TCC/native privilege, or device-local lifecycle?
  yes -> native NeoY capability
  no  -> product/runtime-owned MCP -> federate through NeoY
```

## Repo layout

```
project.yml                  XcodeGen manifest — project/target/scheme = NeoxApp
Neox/
  App/
    NeoxApp.swift            @main; owns ServerController via scenePhase
    StatusScreen.swift       the only UI: endpoint, Siri/Shortcuts handoff
                             preview, tool list, request log, Access-Photos
                             + Clear-Exports buttons
  Server/
    MCPServer.swift          hand-rolled HTTP server on NWListener:
                             JSON-RPC 2.0 at POST /mcp (initialize, tools/list,
                             tools/call, ping), Range-streamed GET /files/,
                             Bonjour advertise (_mcp._tcp), onToolCall hook
    Tool.swift               ToolDefinition / JSONValue (AppAgent-style types)
    ServerController.swift   lifecycle singleton; registers all tools; serves
                             exportsDir at /files/; request log publisher
    DebugTools.swift         agent.handoff — self-test of the phone→bridge
                             handoff path (not part of the media workflow)
    MediaTools.swift         media.search / media.export / media.clear;
                             search supports vision-index filters (has_label /
                             has_text / with_people) + per-row `vision` summary
    VisionTools.swift        media.meta / media.thumbnail / vision.* /
                             video.* (Vision, Speech, AVFoundation)
    VisionIndex.swift        persistent per-asset vision analysis store
                             (actor VisionIndexStore → vision-index.json) +
                             VisionIndexer batch engine + search/meta helpers
  Intents/
    RunAgentIntent.swift     "Run Agent Task": ensure server, compose handoff
                             message, Bonjour-discover the agent bridge and
                             POST to it (clipboard/output fallback);
                             openAppWhenRun (foregrounds for unattended runs);
                             Photos preflight
    AgentBridge.swift        phone-side half of the bridge contract:
                             NWBrowser(_neoy._tcp, TXT host=machine name) →
                             raw-HTTP POST over
                             NWConnection (Gate one-shot latch for races)
    AnalyzeMediaIntent.swift "Analyze Media": batch vision index (days/redo
                             parameters), dialog reports the summary
    AgentHandoff.swift       the ONLY place the agent handoff message is built
                             (instruction + MCP URL; no reasoning here)
    NeoxShortcuts.swift      Siri phrases ("create a vlog with Neox",
                             "analyze my media with Neox", …)
  AgentKit/                  vendored from copilot-ios/AppAgent (NOT an SPM
                             dependency) — remote UI automation for agent-driven
                             self-testing on the device:
    AppAgentToolProvider.swift  `agent.pilot` tool: snapshot/tap/type/swipe/find/
                             scroll_to/pick/screenshot of THIS app's UI
    DemoToolProvider.swift      `agent.demo` tool: spotlight/annotate/caption/say(TTS)/
                             step/cursor/highlight overlays
    DemoRuntime.swift           overlay state machine (+ event recording)
    DemoOverlayView.swift       SwiftUI overlay rendering demo visuals
    AccessibilityScanner.swift  UIKit accessibility tree → refs (r0, r1, …)
    InteractionEngine.swift     tap/type/swipe via UIKit APIs
  Info.plist                 display name, Bonjour service, permission strings
  Neox.entitlements          intentionally empty dict — real entitlements come
                             from the provisioning profile at signing
NeoxTests/                   XCTests hosted in the app; run on the device via
                             `scripts/remote-deploy.sh --test`
skills/
  neox-phone-mcp/             agent-facing skill: concise workflow in
                             SKILL.md, with protocol/troubleshooting
                             references, executable bridge script, and evals.
scripts/remote-deploy.sh     sync + build on mac111 + install on iPhone
```

Hard rules:

- **No third-party dependencies.** Everything is Foundation/AVFoundation/
  Photos/Vision/Speech/Network. Do not add SPM packages. (`AgentKit/` is
  vendored source copied from `copilot-ios/AppAgent` — edit it in place; do
  not re-import the package.)
- **No base64 media in tool results.** Write files into `exportsDir` and return
  `/files/<name>` URLs; the server range-streams them.
- **English + Swifty naming**, dot-namespaced tool names (`media.search`).
- Keep the app target self-contained: nothing may import `copilot-ios`.

## Self-testing on the device

The app embeds its own automation: after deploy, drive and verify the UI from
the Mac over MCP — `agent.pilot` with `snapshot`/`tap`/`type`/`screenshot` and
`agent.demo` for visual overlays. `scripts/remote-deploy.sh --snapshot` and
`--mcp CMD [ARGS]` are shortcuts for this loop.

## Regenerating / building locally

```bash
xcodegen generate            # Neox.xcodeproj is NOT committed
xcodebuild -project Neox.xcodeproj -scheme NeoxApp -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath build-sim build
```

(`Neox.xcodeproj`, `build/`, `build-sim/` are all gitignored.)

## Adding a tool

1. Add a `ToolDefinition` in `MediaTools.swift` or `VisionTools.swift`
   (schema via the `schema()` / `stringProp()` helpers).
2. Handler signature: `(JSONValue) async throws -> String` — return compact
   JSON (`MediaTools.jsonString([…])`) or an error string starting with
   `Error: `.
3. Reuse shared plumbing: `MediaTools.asset(id:)` (auth+fetch),
   `MediaTools.requestImage(_:maxSide:)` (upright CGImage),
   `MediaTools.writeOriginal(asset:to:)` (iCloud-aware original export).
4. The tool auto-appears in `tools/list` and on the status screen
   (`server.toolNames`). No other registration.

## Gotchas learned the hard way

- **PHAsset has no `.orientation`.** `PHImageManager.requestImage` returns
  upright CGImages, so Vision handlers use `.up`.
- **`PHImageRequestOptions` has no `targetSize`** — pass it to
  `requestImage(for:targetSize:…)`.
- **`SFSpeechRecognizer` never fires `isFinal` for speech-less clips** —
  `video.transcribe` guards with `OnceContinuation` + a 90 s watchdog. Keep
  that guard when touching transcribe.
- Never resume a continuation twice; use the existing `OnceContinuation`.
- Image "markers": a tool result string starting `b64:<mime>,` is delivered as
  an MCP image content block; everything else is text.
- **Swift 6 + continuations:** resuming with a non-Sendable value (e.g.
  `AVAsset`) across `withCheckedThrowingContinuation` is a data-race error —
  wrap in the local `SendableBox` (see `VisionIndex.swift`).
- **Swift 6 + locks:** `NSLock` lock/unlock are unavailable from async context
  (`ManagedAtomic` would break the no-deps rule) — guard cross-suspension
  state with a tiny actor gate instead (see `VisionIndexer.RunGate`).
- **App Intents:** `@Parameter` defaults must be compile-time literals
  (constant refs fail); string params can't be Siri phrase placeholders (only
  AppEntity/AppEnum); arg order is `title:` → `description:` → `default:`.
- **Vision index:** batch OCR uses `.accurate` on purpose (search recall beats
  speed; runs are once-per-asset). `total_indexed` must be read from
  `store.totalCount` *after* the run — incrementing per-asset double-counts
  on `redo`.

## Remote build & deploy (iPhone 17 via mac111)

The phone is USB-connected to `mac111` (LAN alias `mac111-lan`, user `chengli`,
keychain password `o7a@bj`). Build there, install over the CoreDevice tunnel:

```bash
./scripts/remote-deploy.sh            # or run the steps below
```

Manual sequence (what the script does):

```bash
# 1. sync sources (NOT build dirs) and regenerate the project remotely
rsync -az --delete --exclude '.git' --exclude 'build' --exclude 'build-sim' \
  --exclude 'Neox.xcodeproj' --exclude 'build-device' ./ mac111-lan:~/Workspace/free2/neox/
ssh mac111-lan 'export PATH=/opt/homebrew/bin:$PATH; cd ~/Workspace/free2/neox \
  && rm -rf Neox.xcodeproj && xcodegen generate'

# 2. keychain unlock MUST precede codesign; build for generic destination
ssh mac111-lan 'security unlock-keychain -p "o7a@bj" ~/Library/Keychains/login.keychain-db
  && xcodebuild -project Neox.xcodeproj -scheme NeoxApp -configuration Debug \
     -destination "generic/platform=iOS" -derivedDataPath build-device/DerivedData \
     PROVISIONING_PROFILE_SPECIFIER="PhoneBridge-Dev" CODE_SIGN_STYLE=Manual \
     CODE_SIGN_IDENTITY="1BFCAE9159CD1B7D0C35B777E072621031F38748" build'

# 3. headless xcodebuild fails signing the Xcode-16 debug dylib → sign by hand,
#    keychain unlock in the SAME ssh session:
APP=~/Workspace/free2/neox/build-device/DerivedData/Build/Products/Debug-iphoneos/Neox.app
#   sign $APP/Neox.debug.dylib, embed
#   ~/Library/MobileDevice/Provisioning Profiles/QL7J5K8T3V.mobileprovision,
#   then sign the bundle with the profile's entitlements (+ get-task-allow)

# 4. install + launch
xcrun devicectl device install app --device FC6AEF41-F3A8-5176-8FEB-841232FF2237 "$APP"
xcrun devicectl device process launch --device FC6AEF41-F3A8-5176-8FEB-841232FF2237 com.neox.app
```

Deployment gotchas (all hit in practice):

- `xcodebuild -destination 'id=<coredevice-uuid>'` times out mounting the
  developer disk image when the phone's iOS is newer than the cached DDI —
  always build `generic/platform=iOS`; `devicectl install` doesn't need the DDI.
- `devicectl` **hangs forever** when the tunnel is down. Wrap in timeouts;
  recover with `sudo pkill -9 CoreDeviceService` on mac111, unlock the phone,
  and re-trust if prompted.
- An iOS app cannot host a reliable inbound LAN listener while backgrounded.
  Rebind on the initial `.active` phase and every foreground return; make the
  desktop producer retry briefly after a handoff rather than claiming
  background-server persistence.
- `security unlock-keychain` must run in the **same SSH session** as any
  `codesign`, or signing fails with `errSecInternalComponent`.
- ASC API JWTs need `iat` from real epoch (`time.time()`, not naive
  `datetime.utcnow()`) and `exp − iat ≤ 20 min`. Device registration uses the
  **legacy UDID** (`00008150-…`), not the CoreDevice id.
- Provisioning profile `PhoneBridge-Dev` (id `QL7J5K8T3V`) covers bundle
  `com.neox.app` + cert `1BFCAE91…` + this iPhone.

## Project learnings

- 2026-09-27: For user-owned iCloud Drive workflows, prefer a native Files folder picker plus a persisted security-scoped bookmark over adding an app-owned iCloud container when the app only needs user-selected folder access. Write cross-device ready markers only after all referenced media bytes are complete.

## Health check after deploy

```bash
curl --max-time 5 http://<phone-ip>:9223/ | jq            # server banner
curl -s -X POST http://<phone-ip>:9223/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | jq '.result.tools[].name'
```

Phone IP is on the status screen; Bonjour `neox._mcp._tcp` also advertises it.
