# Provider-Aware Model Picker — Design 2026-05-10

## Problem

After ccm-relay was wired into `DirectProviderRuntime` and exposed in the picker
(commits `dab1123` + `5931171`), the model picker now mixes 19 entries across
4 providers (OpenAI direct, Anthropic direct, DeepSeek direct, xAI direct,
**CCM Relay** built-in). Users have no way to:

1. Hide direct-provider models for which they do not hold an API key.
2. Understand what `ccm-relay` actually is and why some models have a
   `(Relay)` suffix.
3. Group the picker by provider so the relay variants live next to their direct
   counterparts.

## Goals

- **Built-in relay always on**: no API key, no toggle for the provider itself.
  Routed via the platform credit account (Top Up / Manage Plans sections).
- **Per-model enable/disable**: user picks which models to expose in the picker.
  Default = all `ccm-relay` models enabled; direct-provider models disabled
  unless the user has set an API key for that provider.
- **Picker groups by provider** instead of tier, with provider header showing
  display name + a one-line subtitle (e.g. "Built-in, no API key needed" for
  ccm-relay).
- **Settings → Providers** section explains each provider, lists its models,
  and exposes the toggles.

## Non-goals

- Per-provider API-key UI (already covered by the existing direct-mode flow
  in intento; neox today assumes relay only).
- Cost display (intentionally hidden per `intento-byok-status.md`).
- Custom-provider registration (covered by existing `CustomProvider` flow).

## Design

### Persistence

Add to `NeoxCoreSettings`:

- `enabledModelIdsKey = "enabledModelIds"` — JSON-encoded `[String]`.
- Helper `defaultEnabledModelIds()` returning all `relay-*` IDs.

### Coordinator

Add to `BaseCoordinator`:

```swift
@Published public var enabledModelIds: Set<String> = ...   // load from defaults
                                                          // or default fallback
public var enabledAvailableModels: [ModelInfo] {
    availableModels.filter { enabledModelIds.contains($0.id) }
}
public func setModelEnabled(_ id: String, enabled: Bool) { ... persist ... }
```

If `selectedModel` is not in `enabledModelIds`, the existing fallback logic in
`loadAvailableModels()` already promotes it to a valid one — extend that to
also auto-add `selectedModel` to the enabled set.

### `ModelPickerView`

Add `enum GroupingMode { case tier, family }` plus init parameter. When
`.family`, group rows by `model.family` and render a section header per
family with display name + subtitle. Filter rows to a passed-in
`enabledIds: Set<String>?` (nil = show all).

Family-name formatting helper:

```swift
static func displayName(for family: String) -> String {
    switch family {
    case "ccm-relay": return "CCM Relay"
    case "OpenAI", "Anthropic", "DeepSeek", "xAI": return family
    default: return family.capitalized
    }
}

static func subtitle(for family: String) -> String? {
    family == "ccm-relay" ? "Built-in. No API key needed." : nil
}
```

### Settings → Providers section (`RelaySettingsView`)

New section above "Agent Profile":

```
Providers
┌──────────────────────────────────────────────────────┐
│ CCM Relay                                            │
│ Routes deepseek/claude/openai through                │
│ relay.ai.qili2.com. Billed via your platform credit. │
│ No API key needed.                                   │
│                                                      │
│ Models (3 of 6 enabled)                              │
│  [✓] DeepSeek V4 Flash (Relay)                       │
│  [✓] DeepSeek V4 Pro (Relay)                         │
│  [✓] GPT-4.1 (Relay)                                 │
│  [ ] Claude Sonnet 4 (Relay)                         │
│  ...                                                 │
└──────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────┐
│ DeepSeek (direct)            ⚙ Add API Key           │
│ Direct DeepSeek API.                                 │
│ Models (0 of 2 enabled — set API key to enable)      │
└──────────────────────────────────────────────────────┘
```

Implementation: a new `ProvidersSettingsSection` view (in CopilotChat or
NeoxCore so both apps can reuse it).

### Default state

On first launch:

- `enabledModelIds` = `Set(ModelCatalog.allModels.filter { $0.family == "ccm-relay" }.map(\.id))`
- `selectedModel` = `relay-deepseek-v4-flash` (changed from `deepseek-v4-flash`)
  if no prior selection. Existing users keep their selection.

## Acceptance criteria

- AC1: Picker groups by family with section headers; only enabled models appear.
- AC2: Settings shows a CCM Relay info card; toggling a model updates the
  picker live and persists across app restart.
- AC3: Direct-provider sections appear collapsed/disabled when no API key set
  (visual cue; toggles disabled).
- AC4: First launch enables all 6 relay models; selectedModel = `relay-deepseek-v4-flash`.
- AC5: Toggling off the currently-selected model auto-promotes selection to the
  next enabled model and reconnects.

## Verification

- Unit tests in `CopilotChatTests` (when target builds standalone): grouping,
  filtering, default-set computation.
- Live verify on iPhone 12 mini via AppAgent MCP: open Settings → Providers,
  toggle Claude Sonnet 4 (Relay) on, return to picker → confirm it appears
  under the CCM Relay group, select it, send chat message, verify reply.

## Rollout

Single commit in `copilot-ios` (NeoxCore + CopilotChat). Apps pick up via
symlink. No migration: any existing `selectedModel` not in `enabledModelIds`
auto-adds itself.
