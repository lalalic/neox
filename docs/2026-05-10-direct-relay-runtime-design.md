# Neox Infra Migration — Direct Relay LLM (Phase 2)

> Design + spec to swap Neox's chat/LLM stack from `CopilotBackedRuntime`
> (which depends on a stateful Copilot-CLI relay session) to
> `DirectProviderRuntime` driven by `RelayProviderAdapter`.
>
> Mirrors the architecture co-harness/ccm-harness already use successfully
> (pi-ai's OpenAI-compatible client → CCM Relay HTTP endpoint).

## Motivation

- Copilot-CLI relay sessions are heavy, stateful, and fail in odd ways
  (auth churn, killed sessions, "working" hangs documented in `bugs.md`).
- The relay server (`copilot-relay/`) already exposes
  `POST /llm/v1/chat/completions` (OpenAI-compatible) — used by co-harness
  and ccm-harness without any of the Copilot-CLI baggage.
- `OpenAIAdapter` in `CopilotSDK` already handles the wire protocol.
- `DirectProviderRuntime` already implements session/queue/tool dispatch
  against any `ProviderAdapter` — no further runtime work needed.

## Components

| Layer | Status | File |
|---|---|---|
| LLM wire protocol (OpenAI chat completions + SSE) | ✅ existing | `CopilotSDK/Sources/OpenAIAdapter.swift` |
| Relay-flavoured factory (correct baseURL + provider id) | ✅ added 2026-05-10 | `CopilotSDK/Sources/RelayProviderAdapter.swift` |
| Session runtime (no Copilot-CLI) | ✅ existing | `CopilotSDK/Sources/DirectProviderRuntime.swift` |
| Credential storage (Keychain) | ✅ existing | `CopilotSDK/Sources/CredentialStore.swift` |
| Adapter registration in app | ⏳ next | `Neox/App/NeoxApp.swift` (or AgentCoordinator init) |
| Settings UI for relay bearer | ⏳ next | `Neox/Views/SettingsView.swift` |
| Remove `CopilotBackedRuntime` from default path | ⏳ next | `Neox/Agent/AgentCoordinator.swift` |

## Wiring sketch

```swift
// 1. Build the runtime once at app launch.
let credentialStore = CredentialStore()        // Keychain-backed
let modelRegistry   = ModelRegistry.shared
let usage           = UsageCalculator(...)

let runtime = DirectProviderRuntime(
    sessionId: SessionStore.currentId(),
    credentialStore: credentialStore,
    modelRegistry: modelRegistry,
    sessionStore: SessionStore.shared,
    usageCalculator: usage
)

// 2. Register the relay adapter (and any other direct providers).
let relay = RelayProviderAdapter(usageCalculator: usage)
await runtime.registerAdapter(relay)
await runtime.selectProvider(id: relay.providerId)
await runtime.selectModel(id: "deepseek-v4-flash")  // or whatever

// 3. AgentCoordinator no longer touches CopilotBackedRuntime.
```

## Credentials

- Bearer token (CCM relay JWT) is stored under provider id `ccm-relay` via
  `CredentialStore.set(...)`.
- Settings UI prompts the user once, then validates via
  `RelayProviderAdapter.validateCredentials(apiKey:, baseURL:)`.
- Token rotation is a normal Settings re-save — no app restart required.

## Test plan (matches co-harness)

| # | Story | Verification |
|---|---|---|
| 1 | App launches, sees relay configured, can list models | UI smoke (sim) |
| 2 | Send "reply 4" → assistant text "4" appears within 30 s | Live device |
| 3 | Tool call (e.g. read_file) round-trips through `DirectProviderRuntime` | Sim + device |
| 4 | Auth error surfaces in chat (no silent hang) | Set bad token, send a prompt — must show error message |
| 5 | Switching from CopilotBacked → DirectProvider preserves history | Migration spike |

For #2-#5 we need the test box `10.0.0.111` (per user-steer 2026-05-10) with an
iPhone 12 mini connected so xcodebuild test-without-building can drive
`NeoxUITests` against the live build.

## Risks

- Relay JWT lifetime — once expired, prompts hang silently on Copilot-CLI today.
  With OpenAI/Direct path the upstream returns 401 → adapter throws → runtime
  emits a `chat error` event. Confirm Settings catches this and re-prompts.
- Usage tracking: `UsageCalculator` already lives in `CopilotSDK`. Confirm the
  same instance is shared between relay-fronted and any local-adapter paths so
  the global balance ticker stays accurate.
- Tool definitions: `ProviderToolDefinition` shape is OpenAI-style; adapters
  (Anthropic) translate. Relay passes through, so OpenAI shape is correct.

## Next concrete steps

1. Wire `RelayProviderAdapter` into `AgentCoordinator.init` behind a feature
   flag (`UserDefaults.standard.bool(forKey: "useDirectRuntime")`).
2. Add a "Direct Provider (Relay)" toggle to Settings.
3. On the test box (10.0.0.111) run the user-stories suite from
   `Neox/E2E - user stories.md` — record any regressions vs. CopilotBacked.
4. Once parity is confirmed, flip the default and start removing
   `CopilotBackedRuntime` references.
