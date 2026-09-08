# AGENTS.md — machine-room notes for working on Neox

Instructions for coding agents (and humans) modifying this repo.

## What this is

`Neox` — a headless iPhone app that serves the phone's photo/video library to
desktop agents over MCP. One app target, zero external SPM dependencies, 14
tracked files. Source of truth for behavior: `Neox/Server/`.

## Repo layout

```
project.yml                  XcodeGen manifest — project/target/scheme = NeoxApp
Neox/
  App/
    NeoxApp.swift            @main; owns ServerController via scenePhase
    StatusScreen.swift       the only UI: endpoint, tool list, request log,
                             Access-Photos + Clear-Exports buttons
  Server/
    MCPServer.swift          hand-rolled HTTP server on NWListener:
                             JSON-RPC 2.0 at POST /mcp (initialize, tools/list,
                             tools/call, ping), Range-streamed GET /files/,
                             Bonjour advertise (_mcp._tcp), onToolCall hook
    Tool.swift               ToolDefinition / JSONValue (AppAgent-style types)
    ServerController.swift   lifecycle singleton; registers all tools; serves
                             exportsDir at /files/; request log publisher
    MediaTools.swift         media.search / media.export / clear_exports
    VisionTools.swift        media.meta / media.thumbnail / vision.* /
                             video.* (Vision, Speech, AVFoundation)
  Intents/
    RunAgentIntent.swift     App Intents entry point: ensure server, compose
                             handoff message, clipboard fallback, output value
    AgentHandoff.swift       the ONLY place the agent handoff message is built
                             (instruction + MCP URL; no reasoning here)
    NeoxShortcuts.swift      Siri phrases ("create a vlog with Neox", …)
  AgentKit/                  vendored from copilot-ios/AppAgent (NOT an SPM
                             dependency) — remote UI automation for agent-driven
                             self-testing on the device:
    AppAgentToolProvider.swift  `app_agent` tool: snapshot/tap/type/swipe/find/
                             scroll_to/pick/screenshot of THIS app's UI
    DemoToolProvider.swift      `demo` tool: spotlight/annotate/caption/say(TTS)/
                             step/cursor/highlight overlays
    DemoRuntime.swift           overlay state machine (+ event recording)
    DemoOverlayView.swift       SwiftUI overlay rendering demo visuals
    AccessibilityScanner.swift  UIKit accessibility tree → refs (r0, r1, …)
    InteractionEngine.swift     tap/type/swipe via UIKit APIs
  Info.plist                 display name, Bonjour service, permission strings
  Neox.entitlements          intentionally empty dict — real entitlements come
                             from the provisioning profile at signing
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
the Mac over MCP — `app_agent` with `snapshot`/`tap`/`type`/`screenshot` and
`demo` for visual overlays. `scripts/remote-deploy.sh --snapshot` and
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
- `security unlock-keychain` must run in the **same SSH session** as any
  `codesign`, or signing fails with `errSecInternalComponent`.
- ASC API JWTs need `iat` from real epoch (`time.time()`, not naive
  `datetime.utcnow()`) and `exp − iat ≤ 20 min`. Device registration uses the
  **legacy UDID** (`00008150-…`), not the CoreDevice id.
- Provisioning profile `PhoneBridge-Dev` (id `QL7J5K8T3V`) covers bundle
  `com.neox.app` + cert `1BFCAE91…` + this iPhone.

## Health check after deploy

```bash
curl --max-time 5 http://<phone-ip>:9223/ | jq            # server banner
curl -s -X POST http://<phone-ip>:9223/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | jq '.result.tools[].name'
```

Phone IP is on the status screen; Bonjour `neox._mcp._tcp` also advertises it.
