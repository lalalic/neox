# Mobile engineering and verification

Use `project.yml` as XcodeGen source, `Neox/App/` for Chat, Jobs, Review Inbox and Connector, `Neox/Server/` for MCP and media tools, `Neox/Intents/` for Siri/handoff, and `NeoxTests/` for verification. Use the public AppCopilotKit package for UI automation and demos, not vendored copies. Reuse existing MCP registration and media helpers. Use English/Swifty names and dot-namespaced tools. Range-stream exported media; no base64 video payload. Trust-bind control endpoints and never expose unauthenticated UI automation.

## Gateway and device truth

`UnifiedGatewayREST.swift` and `ChatGatewayView.swift` consume authenticated `/orchestrator-chat/*` and `/relay/api/*`; the Master owns durable state. Jobs use durable creation time, active first, allowlisted lifecycle activity, last successful snapshot on transient failures, and explicit supported cancellation with exact repository/Job ID, confirmation and authoritative readback. Test older gateways and cross-repository ID collisions. Bonjour is proximity, not remote availability. Probe the saved authenticated HTTPS endpoint with its bound Keychain token; never redirect a token to a newly discovered URL. Verify remote connectivity and UI on the actual phone before claiming installed success.

## Media, Swift and Intents

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

## Build and delivery

Use current XcodeGen settings and [repository build guidance](../README.md#building), not historical manual signing commands. Keep generated Xcode and build state untracked. Validate compile and relevant tests; signed installation, real device behavior and TestFlight availability are distinct gates. Use authorized existing device delivery procedures; no secret or device-specific signing material in tracked guidance. Preserve task-owned sessions and private media. Foreground-only iOS inbound listeners must rebind on active transitions. Use generic iOS device builds when developer disk mounting is unavailable; verify signing/installation and connection separately.
