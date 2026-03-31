# Design: Payment & Usage Tracking System

> **Status:** Refined — decisions confirmed, ready for final review before coding  
> **Priority:** P0  
> **Date:** 2025-07-17 (refined 2025-07-17)

---

## Decisions (User Confirmed)

- **Pricing**: Credit packs (not subscriptions)
- **Free tier**: $2 worth of tokens on any model (no message/model restrictions)
- **Authority**: **Client-authoritative** — device tracks balance locally, no server balance management
- **Model catalog**: Dynamic fetch from GitHub Models API
- **First phase**: Refine design → implement tracking → payment later

---

## 1. Problem Statement

Neox uses GitHub Models via Copilot CLI as its LLM backend. Each model has different per-token pricing. We need to:

1. **Track token usage** per session and lifetime on device
2. **Show real-time cost** to the user as they chat
3. **Support payment** via Apple IAP credit packs
4. **Select models** with transparent pricing (fetched dynamically)

---

## 2. Architecture Overview

**Client-authoritative** — the iOS device is the single source of truth for balance and usage. The relay optionally logs usage for analytics but does NOT enforce balance.

```
┌──────────────────────────────────┐
│  iOS App (Neox)                  │
│                                  │
│  ┌────────────────────────────┐  │
│  │ UsageTracker               │  │
│  │  └─ subscribes to          │  │
│  │     assistant.usage events │  │
│  │  └─ accumulates tokens +   │  │
│  │     cost per session/life  │  │
│  │  └─ deducts from balance   │  │
│  │  └─ persists to UserDefaults│ │
│  ├────────────────────────────┤  │
│  │ CostCalculator             │  │
│  │  └─ dynamic multipliers    │  │
│  │     fetched from API       │  │
│  │  └─ hardcoded fallback     │  │
│  ├────────────────────────────┤  │
│  │ PaymentManager (StoreKit2) │  │
│  │  └─ credit packs via IAP   │  │
│  │  └─ adds to local balance  │  │
│  └────────────────────────────┘  │
└──────────┬───────────────────────┘
           │ WebSocket (JSON-RPC)
           ▼
┌──────────────────────────────────┐
│  Relay Server (Node.js)          │
│  └─ forwards assistant.usage     │
│     events to client (existing)  │
│  └─ optional: log to usage.jsonl │
│     for analytics (no balance    │
│     enforcement)                 │
└──────────┬───────────────────────┘
           │ stdin/stdout
           ▼
┌──────────────────────────────────┐
│  Copilot CLI                     │
│  └─ session.event                │
│     type: assistant.usage        │
│     data: { prompt_tokens,       │
│       completion_tokens, model } │
└──────────────────────────────────┘
```

---

## 3. Data Flow

### 3.1 Source: `assistant.usage` Event

Copilot CLI emits `session.event` with `type: "assistant.usage"` after each LLM call. CopilotSDK already defines `SessionEventType.assistantUsage`. Expected payload:

```json
{
  "jsonrpc": "2.0",
  "method": "session.event",
  "params": {
    "sessionId": "neox-pool-0",
    "event": {
      "type": "assistant.usage",
      "data": {
        "prompt_tokens": 1234,
        "completion_tokens": 567,
        "total_tokens": 1801,
        "model": "gpt-4.1"
      }
    }
  }
}
```

### 3.2 Flow

1. CLI emits `assistant.usage` → relay forwards to iOS client (already happens)
2. `ChatViewModel` subscribes to `.assistantUsage` → calls `UsageTracker.record()`
3. `UsageTracker` calculates cost using `CostCalculator.multipliers(for: model)`
4. Cost deducted from local balance, UI updated in real-time
5. Balance + lifetime usage persisted to UserDefaults

---

## 4. Pricing

### 4.1 GitHub Models Token Units

$0.00001 per token unit. Per-model multipliers:

| Model | Input Mult | Output Mult | Approx $/100K tokens |
|-------|-----------|-------------|---------------------|
| gpt-4.1 | 0.20 | 0.80 | $0.50 |
| gpt-4.1-mini | 0.04 | 0.16 | $0.10 |
| gpt-4.1-nano | 0.01 | 0.04 | $0.025 |
| gpt-4o | 0.25 | 1.00 | $0.625 |
| gpt-4o-mini | 0.015 | 0.06 | $0.0375 |
| o3 | 1.00 | 4.00 | $2.50 |
| DeepSeek-R1 | 0.135 | 0.54 | $0.3375 |
| Claude Sonnet 4 | 0.30 | 1.50 | $0.90 |
| Claude Opus 4 | 1.50 | 7.50 | $4.50 |

**Note:** Multipliers fetched dynamically from `GET https://models.github.ai/catalog/models` with hardcoded fallback.

### 4.2 Cost Formula

```
cost = (prompt_tokens × input_mult + completion_tokens × output_mult) × $0.00001
```

### 4.3 Credit Packs (Apple IAP)

| Product ID | Name | Price | Token Value | Markup |
|-----------|------|-------|-------------|--------|
| `com.neox.credits.starter` | Starter | $4.99 | $3.50 | 1.43× |
| `com.neox.credits.standard` | Standard | $9.99 | $7.50 | 1.33× |
| `com.neox.credits.pro` | Pro | $29.99 | $25.00 | 1.20× |

Apple takes 30% → effective markup after Apple cut:
- Starter: $4.99 → $3.49 for us → $3.50 to user → **break-even**
- Standard: $9.99 → $6.99 for us → $7.50 to user → needs adjustment
- Pro: $29.99 → $20.99 for us → $25.00 to user → needs adjustment

**TODO**: Adjust credit values so we maintain ~20-30% margin after Apple's cut.

### 4.4 Free Tier

Every new install gets **$2.00 worth of tokens** — unrestricted model access. This covers approximately:
- ~400K tokens on gpt-4.1 (enough for ~50-100 conversations)
- ~8M tokens on gpt-4.1-nano (hundreds of conversations)
- ~80K tokens on o3 (a handful of complex reasoning tasks)

When balance hits $0, show purchase prompt.

---

## 5. Component Design

### 5.1 `ModelCatalog` — Dynamic Model Fetcher

```swift
/// Fetches and caches model catalog from GitHub Models API.
@MainActor
public class ModelCatalog: ObservableObject {
    struct ModelInfo: Codable, Identifiable {
        let id: String          // e.g., "gpt-4.1"
        let name: String        // display name
        let inputMultiplier: Double
        let outputMultiplier: Double
        let description: String?
        let maxInputTokens: Int?
        let maxOutputTokens: Int?
    }
    
    @Published var models: [ModelInfo] = []
    @Published var lastFetchDate: Date?
    
    private static let cacheKey = "neox.models.catalog"
    private static let apiURL = URL(string: "https://models.github.ai/catalog/models")!
    
    /// Fetch models from API. Falls back to cached/hardcoded if offline.
    func refresh() async {
        do {
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let catalog = try JSONDecoder().decode([APICatalogModel].self, from: data)
            models = catalog.compactMap { mapToModelInfo($0) }
            lastFetchDate = Date()
            persistCache()
        } catch {
            loadCacheOrDefaults()
        }
    }
    
    func multipliers(for modelId: String) -> (input: Double, output: Double) {
        if let m = models.first(where: { $0.id == modelId }) {
            return (m.inputMultiplier, m.outputMultiplier)
        }
        return CostCalculator.fallbackMultipliers(for: modelId)
    }
}
```

### 5.2 `UsageTracker` — Client-Authoritative Balance

```swift
/// Client-authoritative usage and balance tracker.
/// Persists all data to UserDefaults — no server sync needed.
@MainActor
public class UsageTracker: ObservableObject {
    // --- Balance ---
    @Published var balance: Double = 2.00  // Start with $2 free credits
    
    // --- Session Usage ---
    @Published var sessionCost: Double = 0.0
    @Published var sessionTokens: Int = 0
    
    // --- Lifetime Usage ---
    @Published var lifetimeCost: Double = 0.0
    @Published var lifetimeTokens: Int = 0
    
    // --- Per-model breakdown ---
    @Published var sessionUsageByModel: [String: TokenUsage] = [:]
    
    struct TokenUsage: Codable {
        var promptTokens: Int = 0
        var completionTokens: Int = 0
        var cost: Double = 0.0
    }
    
    private let catalog: ModelCatalog
    
    init(catalog: ModelCatalog) {
        self.catalog = catalog
        loadPersisted()
    }
    
    /// Record a single assistant.usage event.
    func record(_ data: JSONValue) {
        guard case .object(let dict) = data else { return }
        let model = dict["model"].stringValue ?? "unknown"
        let promptTokens = dict["prompt_tokens"].intValue ?? 0
        let completionTokens = dict["completion_tokens"].intValue ?? 0
        
        let (inMult, outMult) = catalog.multipliers(for: model)
        let cost = (Double(promptTokens) * inMult + Double(completionTokens) * outMult) * 0.00001
        
        // Update session
        var usage = sessionUsageByModel[model] ?? TokenUsage()
        usage.promptTokens += promptTokens
        usage.completionTokens += completionTokens
        usage.cost += cost
        sessionUsageByModel[model] = usage
        
        sessionCost += cost
        sessionTokens += promptTokens + completionTokens
        
        // Update lifetime
        lifetimeCost += cost
        lifetimeTokens += promptTokens + completionTokens
        
        // Deduct from balance
        balance -= cost
        if balance < 0 { balance = 0 }
        
        persist()
    }
    
    /// Add purchased credits to balance.
    func addCredits(_ amount: Double) {
        balance += amount
        persist()
    }
    
    /// Reset session counters (on new session).
    func resetSession() {
        sessionCost = 0
        sessionTokens = 0
        sessionUsageByModel = [:]
    }
    
    // --- Persistence (UserDefaults) ---
    
    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(balance, forKey: "neox.balance")
        defaults.set(lifetimeCost, forKey: "neox.lifetime.cost")
        defaults.set(lifetimeTokens, forKey: "neox.lifetime.tokens")
    }
    
    private func loadPersisted() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "neox.balance") != nil {
            balance = defaults.double(forKey: "neox.balance")
        }
        lifetimeCost = defaults.double(forKey: "neox.lifetime.cost")
        lifetimeTokens = defaults.integer(forKey: "neox.lifetime.tokens")
    }
}
```

### 5.3 `CostCalculator` — Hardcoded Fallback

```swift
/// Static fallback multipliers when API is unavailable.
enum CostCalculator {
    struct Multipliers {
        let input: Double
        let output: Double
    }
    
    static let fallbacks: [String: Multipliers] = [
        "gpt-4.1":         Multipliers(input: 0.20, output: 0.80),
        "gpt-4.1-mini":    Multipliers(input: 0.04, output: 0.16),
        "gpt-4.1-nano":    Multipliers(input: 0.01, output: 0.04),
        "gpt-4o":          Multipliers(input: 0.25, output: 1.00),
        "gpt-4o-mini":     Multipliers(input: 0.015, output: 0.06),
        "o4-mini":         Multipliers(input: 0.11, output: 0.44),
        "o3":              Multipliers(input: 1.00, output: 4.00),
        "o3-mini":         Multipliers(input: 0.11, output: 0.44),
        "DeepSeek-R1":     Multipliers(input: 0.135, output: 0.54),
        "Grok-3":          Multipliers(input: 0.30, output: 1.50),
        "Claude-Sonnet-4": Multipliers(input: 0.30, output: 1.50),
        "Claude-Opus-4":   Multipliers(input: 1.50, output: 7.50),
    ]
    
    static func fallbackMultipliers(for model: String) -> (input: Double, output: Double) {
        if let m = fallbacks[model] { return (m.input, m.output) }
        for (key, m) in fallbacks where model.lowercased().contains(key.lowercased()) {
            return (m.input, m.output)
        }
        return (0.25, 1.00)  // default to gpt-4o
    }
    
    static func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return String(format: "$%.4f", cost) }
        return String(format: "$%.2f", cost)
    }
}
```

### 5.4 `PaymentManager` — StoreKit 2

```swift
/// Manages Apple IAP credit purchases.
@MainActor
public class PaymentManager: ObservableObject {
    @Published var products: [Product] = []
    @Published var isPurchasing = false
    
    private let usageTracker: UsageTracker
    
    static let productIDs = [
        "com.neox.credits.starter",   // $4.99 → $3.50
        "com.neox.credits.standard",  // $9.99 → $7.50
        "com.neox.credits.pro",       // $29.99 → $25.00
    ]
    
    static let creditValues: [String: Double] = [
        "com.neox.credits.starter": 3.50,
        "com.neox.credits.standard": 7.50,
        "com.neox.credits.pro": 25.00,
    ]
    
    init(usageTracker: UsageTracker) {
        self.usageTracker = usageTracker
    }
    
    func loadProducts() async {
        do {
            products = try await Product.products(for: Set(Self.productIDs))
                .sorted { ($0.price as NSDecimalNumber).doubleValue < ($1.price as NSDecimalNumber).doubleValue }
        } catch {
            print("Failed to load products: \(error)")
        }
    }
    
    func purchase(_ product: Product) async throws {
        isPurchasing = true
        defer { isPurchasing = false }
        
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            if let credits = Self.creditValues[product.id] {
                usageTracker.addCredits(credits)
            }
            await transaction.finish()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe): return safe
        }
    }
}
```

### 5.5 Chat UI Integration

**ChatViewModel additions:**

```swift
// In subscribeToEvents():
await session.on(.assistantUsage) { [weak self] event in
    guard let self else { return }
    Task { @MainActor in
        self.usageTracker.record(event.data)
    }
}
```

**Chat header cost badge:**

```swift
HStack {
    Text(viewModel.currentModel)
        .font(.caption)
        .foregroundStyle(.secondary)
    Spacer()
    Text(CostCalculator.formatCost(viewModel.usageTracker.sessionCost))
        .font(.caption.monospacedDigit())
        .foregroundStyle(viewModel.usageTracker.balance < 0.50 ? .red : .secondary)
}
```

**Balance warning:**

```swift
if usageTracker.balance < 0.50 {
    // Show banner: "Low balance: $0.32 remaining. Top up?"
}
if usageTracker.balance <= 0 {
    // Show purchase sheet
}
```

### 5.6 Model Selection UI

```swift
struct ModelPickerView: View {
    @ObservedObject var catalog: ModelCatalog
    @Binding var selectedModel: String
    
    var body: some View {
        List(catalog.models) { model in
            Button {
                selectedModel = model.id
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(model.name).font(.headline)
                        if let desc = model.description {
                            Text(desc).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    let cost100k = (50000 * model.inputMultiplier + 50000 * model.outputMultiplier) * 0.00001
                    Text(CostCalculator.formatCost(cost100k) + "/100K")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if model.id == selectedModel {
                        Image(systemName: "checkmark").foregroundStyle(.blue)
                    }
                }
            }
        }
        .navigationTitle("Select Model")
        .task { await catalog.refresh() }
    }
}
```

---

## 6. Relay-Side (Minimal — Analytics Only)

Since balance is client-authoritative, the relay's role is minimal. Optional analytics logging:

```javascript
// In routeFromCli(), alongside existing event interception:
if (msg.params?.event?.type === 'assistant.usage') {
    const data = msg.params.event.data || {};
    const record = {
        ts: new Date().toISOString(),
        sid: sid,
        model: data.model,
        in: data.prompt_tokens,
        out: data.completion_tokens,
    };
    fs.appendFile(
        path.join(this.cwd, '.usage.jsonl'),
        JSON.stringify(record) + '\n',
        () => {}
    );
}
```

No balance management, no accounts.json, no HTTP usage API needed.

---

## 7. Data Model (Client-Side Only)

```swift
// UserDefaults persistence:
"neox.balance"          → Double (current credit balance, starts at 2.00)
"neox.lifetime.cost"    → Double (total $ consumed ever)
"neox.lifetime.tokens"  → Int (total tokens consumed ever)
"neox.models.catalog"   → Data (cached JSON from API)
"neox.models.lastFetch" → Date
```

No server-side account storage. The device IS the account.

---

## 8. Implementation Plan

### Phase 1: Usage Tracking + Cost Display
1. `ModelCatalog` — fetch from GitHub Models API + hardcoded fallback
2. `CostCalculator` — static fallback multipliers
3. `UsageTracker` — record events, deduct from balance, persist to UserDefaults
4. `ChatViewModel` — subscribe to `.assistantUsage`, wire to UsageTracker
5. Chat UI — session cost badge in header, balance indicator
6. **Relay** — optional analytics logging (~10 lines)

### Phase 2: Model Selection
7. `ModelPickerView` — list models with cost info
8. Settings → model picker
9. Pass selected model in `session.create` / agent config

### Phase 3: Payment (Apple IAP)
10. `PaymentManager` — StoreKit 2 product loading + purchase
11. Settings → "Buy Credits" section
12. Low-balance warning + purchase prompt
13. App Store Connect: create consumable products

---

## 9. Risks

| Risk | Mitigation |
|------|------------|
| `assistant.usage` not emitted by CLI | Add debug logging to verify; fallback to token estimation |
| Client-authoritative is "hackable" | Acceptable — users hacking their own balance doesn't cost us extra (GitHub Models charges per-token to our account regardless) |
| GitHub Models API format changes | Hardcoded fallback always available |
| Apple IAP review | Keep app functional without IAP; credits are additional |
| Device data loss (reinstall) | Balance gone — acceptable for v1; could add iCloud KeyValueStore later |

---

## 10. Remaining Questions

1. **`assistant.usage` payload**: Need to verify exact fields from CLI. Add debug logging first?
2. **Zero balance behavior**: Hard block (force purchase) or soft degrade (allow nano only)?
3. **Credit values**: Need to finalize after accounting for Apple's 30% cut.
4. **iCloud sync**: Should balance persist across reinstalls via iCloud KeyValueStore?
