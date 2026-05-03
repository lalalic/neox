# WeChat Contact Routing Design

> **Date**: 2026-04-01  
> **Status**: Draft v3 — awaiting approval  
> **Goal**: WeChat as a service in Neox with its own WebKit — route agent output to selected WeChat contacts

---

## Problem

When the AI agent calls `send_response` or `ask_questions`, the response only shows in the in-app chat UI. The user wants:
1. WeChat as a **toggleable service** (enable/disable in Settings)
2. A **status indicator** in the chat toolbar (green=online, gray=offline)
3. **Click-to-toggle routing** (turn forwarding on/off from the toolbar)
4. **Multi-contact selection** per project AND on the main (all-projects) chat
5. Agent messages forwarded to selected WeChat contacts

---

## Design

### 1. WeChat Service (Settings)

In `RelaySettingsView` (Settings sheet), add a **WeChat Channel** section:

```
┌─ Settings ──────────────────────┐
│  Relay: relay.ai.qili2.com      │
│  Model: gpt-4.1                 │
│  ─────────────────────────────  │
│  WeChat Channel                 │
│  [Toggle: ON/OFF]               │
│  Status: Connected ●            │
│  Logged in as: John             │
│  [Show QR Code]                 │  ← shows QR for scanning (from WeChatChannel)
│  ─────────────────────────────  │
│  Plans / Files / Credits...     │
└─────────────────────────────────┘
```

- Toggle enables/disables the WeChat channel globally
- When enabled, creates `WeChatChannel` instance with its **own private WKWebView** (no sharing with globe browser)
- `WeChatChannel` handles: wx.qq.com loading, QR code extraction, login monitoring, contact fetching, message sending
- Shows QR code for scanning (using `WeChatChannel.generateQRCode(from:)`)
- Shows login status, user name
- Persisted in UserDefaults

### 2. Chat Toolbar Status Indicator

In the NavigationBar (top of ChatView):

```
┌────────────────────────────────────────┐
│ [Album][🌐]    Neo    [💬●][⚙️]       │
│                       ↑ WeChat icon    │
│                       green=online+routing
│                       yellow=online, routing off
│                       gray=offline     │
└────────────────────────────────────────┘
```

- **💬 icon** (or WeChat logo SF Symbol) next to the gear button
- **Color states**:
  - 🟢 Green: WeChat online + routing active (messages being forwarded)
  - 🟡 Yellow: WeChat online but routing paused/off
  - ⚫ Gray: WeChat offline/disabled
- **Tap** toggles routing on/off for the current context (project or main chat)
- **Long press** opens the contact selector for current context

### 3. Contact Selector

A sheet with the contact list from WeChat:

```
┌─ Select Contacts ──────────────┐
│ 🔍 Search...                   │
│ ──────────────────────────────  │
│ [✓] John Zhang                 │
│ [ ] Marketing Group  (group)   │
│ [✓] Alice Wang                 │
│ [ ] Dev Team  (group)          │
│ ...                            │
│ ──────────────────────────────  │
│ [Done]  [Clear All]            │
└────────────────────────────────┘
```

- Multi-select (checkmarks)
- Shows individual contacts + groups (rooms)
- Search by name
- Separate binding per context:
  - "Main chat" (applies when no project selected, or "All Projects")
  - Each project has its own contact set

### 4. Data Model

```swift
/// Global WeChat service state
/// Stored in UserDefaults
struct WeChatServiceConfig: Codable {
    var enabled: Bool = false
    var routingActive: Bool = false  // global toggle
}

/// Contact binding for a context (project or main)
/// Stored in <workspace>/.neo/wechat-contacts.json (main)
/// or <workspace>/<project>/.neo/wechat-contacts.json (per-project)
struct WeChatContactBindings: Codable {
    var contacts: [BoundContact]
    var routingActive: Bool = true
    
    struct BoundContact: Codable, Identifiable {
        let id: String        // contactUserName
        let name: String      // display name
        let isRoom: Bool
    }
}
```

### 5. Agent Output Routing Flow

```
Agent calls send_response("Result: ...")
    │
    ▼
ChatViewModel.handleAgentResponse(message)  // shows in UI (existing)
    │
    ▼
AgentConfig.onResponse(message)  // callback we provide
    │
    ▼
WeChatService.forward(message, project: current)
    │
    ├─ Is WeChat enabled & online? → No → return
    ├─ Is routing active for this context? → No → return
    ├─ Get bound contacts for current project (or main if no project)
    └─ For each bound contact:
         weChatChannel.sendMessage(to: contact.id, content: message)
```

Uses `WeChatChannel.sendMessage(to:content:)` directly — not the YAML site adapter.
`WeChatChannel` has its own private `WKWebView`, runs independently of the globe browser.

### 6. WeChatService (new coordinator-level service)

```swift
/// Manages WeChat channel lifecycle and forwarding
@MainActor
final class WeChatService: ObservableObject {
    @Published var config: WeChatServiceConfig
    @Published var channel: WeChatChannel?  // nil when disabled
    
    // Derived from channel state
    var isOnline: Bool { channel?.state == .ready }
    var loggedInUser: String? { channel?.loggedInUser?.name }
    var contacts: [WeChatContact] { channel?.contacts ?? [] }
    
    // Contact bindings per context
    @Published var mainBindings: WeChatContactBindings
    private var projectBindings: [String: WeChatContactBindings] = [:]
    
    var statusColor: Color {
        guard config.enabled else { return .gray }
        guard isOnline else { return .gray }
        if !isRoutingActive(for: currentProject) { return .yellow }
        return .green
    }
    
    func enable() {
        let ch = WeChatChannel()  // creates its own private WKWebView (1280x900)
        ch.onStateChange = { [weak self] state in /* update published state */ }
        ch.start()  // loads wx.qq.com, extracts QR, waits for scan
        self.channel = ch
    }
    
    func disable() {
        channel?.destroy()
        channel = nil
    }
    
    func toggleRouting(for project: String?) { ... }
    func bindContacts(_ contacts: [BoundContact], project: String?) { ... }
    
    func forward(message: String, project: String?) async {
        guard config.enabled, isOnline else { return }
        let bindings = getBindings(for: project)
        guard bindings.routingActive else { return }
        for contact in bindings.contacts {
            _ = await channel?.sendMessage(to: contact.id, content: message)
        }
    }
}
```

Key: `WeChatChannel` has its **own WKWebView** — the globe browser remains free for other browsing.

### 7. File Changes

| File | Change | Effort |
|------|--------|--------|
| **New**: `Neox/Services/WeChatService.swift` | Service coordinator, forwarding logic, persistence | Medium |
| **New**: `Neox/Views/ContactSelectorView.swift` | Multi-select contact picker sheet | Medium |
| **New**: `Neox/Views/WeChatStatusIndicator.swift` | Toolbar icon with color state | Small |
| `Neox/Agent/AgentCoordinator.swift` | Create WeChatService, wire `onResponse` | Medium |
| `Neox/App/ContentView.swift` | Add status indicator to toolbar, handle sheets | Small |
| `Neox/App/NeoxApp.swift` | Initialize WeChatService as @StateObject | Small |
| Settings in `CopilotChat/Sources/Views/` or `Neox/Views/` | WeChat toggle section | Small |

### 8. Testing Strategy

| Test | What |
|------|------|
| Unit: WeChatService | Config persistence, binding load/save, routing logic |
| Unit: ContactSelector | Multi-select state, search filtering |
| Integration: Forwarding | Mock web_agent, verify send called for each bound contact |
| Device: Full flow | Login via browser → select contacts → trigger agent → verify WeChat messages |

---

## Non-Goals (Future)

- **Bidirectional**: WeChat replies routed back to agent (WeChatChannel has `onMessage` callback — can be wired later)
- **Per-message routing control**: Currently all-or-nothing per context
- **ask_questions forwarding**: Requires bidirectional to work meaningfully
- **Incoming message display**: Showing WeChat messages in the chat UI (requires bidirectional)
