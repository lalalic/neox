# Deep Dive: Backend Architecture (CopilotSDK)

## The Big Picture

The app has **no server of its own**. The backend IS GitHub Copilot CLI, running on a Mac (or anywhere). CopilotSDK connects to it via TCP/WebSocket and speaks JSON-RPC. The CLI does all the heavy lifting — model calls, tool execution, file system access, code generation.

```
iPhone (Neox)  ──── TCP/WiFi ────  Mac (Copilot CLI)
                                      │
                                      ├── GPT-4.1 / Claude / etc.
                                      ├── File system (workspaces)
                                      ├── Terminal (shell commands)
                                      └── MCP servers (extensions)
```

---

## Transport Options

### 1. TCP (Local Network) — Recommended for Dev
```swift
let transport = TCPTransport(host: "192.168.1.100", port: 8080)
```
- Phone and Mac on same WiFi
- Low latency (~1-5ms)
- No relay server needed
- Copilot CLI runs: `copilot --headless --server --port 8080`

### 2. WebSocket (Relay Server) — For Remote Access
```swift
let transport = WebSocketTransport(url: URL(string: "wss://relay.example.com")!)
```
- Works across networks (phone on cellular, Mac at home)
- Needs a small relay server (Node.js/Python, ~50 lines)
- The relay spawns a Copilot CLI process per WebSocket connection
- Could be deployed on a VPS for always-on access

### 3. Stdio (On-Device) — Future/Experimental
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/path/to/copilot")
let transport = StdioTransport(process: process)
```
- Would require Copilot CLI compiled for iOS (not possible today)
- Could work on macOS Catalyst
- Future: if Apple Silicon Macs can run CLI tools from iOS apps

### Recommended Architecture

```
┌──────────────────────────────────┐
│           Development            │
│  iPhone ←──TCP──→ Mac (local)    │
│  Fast, no internet needed        │
└──────────────────────────────────┘

┌──────────────────────────────────┐
│           Production             │
│  iPhone ←─WSS─→ Relay ←──→ CLI  │
│  Works anywhere, auto-reconnect  │
└──────────────────────────────────┘

┌──────────────────────────────────┐
│           Hybrid                 │
│  Try TCP first → fallback to WS  │
│  Best of both worlds             │
└──────────────────────────────────┘
```

---

## Connection Lifecycle

### Auto-Discovery
Instead of typing IP addresses:
1. **Bonjour/mDNS** — Mac advertises `_copilot._tcp` service on local network
2. Phone discovers it automatically
3. One-tap connect
4. Falls back to manual IP:port entry

### Connection Management
```swift
class ConnectionManager: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var latency: TimeInterval = 0
    
    func connect() async {
        // 1. Try last known TCP host
        // 2. Scan Bonjour for _copilot._tcp
        // 3. Try WebSocket relay
        // 4. Show manual entry
    }
    
    func autoReconnect() {
        // Exponential backoff: 1s, 2s, 4s, 8s, max 30s
        // Switch transport if TCP fails repeatedly
    }
}
```

### State Machine
```
disconnected → connecting → connected → (session active)
     ↑              │            │              │
     └──────────────┘            └──────────────┘
         (failure)                  (disconnect)
```

---

## Session Management

Each "project" in the app maps to a Copilot session:

### Session = Project
```swift
struct Project: Identifiable {
    let id: String          // = sessionId
    var name: String        // user-given name
    var model: String       // gpt-4.1, claude-sonnet-4.5, etc.
    var lastActive: Date
    var workingDirectory: String?
    var messageCount: Int
}
```

### Session Operations
```swift
// Create new project
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    tools: allTools,           // WebKitAgent + custom tools
    streaming: true,
    infiniteSessions: InfiniteSessionConfig(enabled: true)  // never run out of context
))

// List all projects
let sessions = try await client.listSessions()

// Resume a project
let session = try await client.resumeSession(sessionId: project.id, config: ...)

// Delete a project
try await client.deleteSession(project.id)
```

### Infinite Sessions
Context window never fills up. The SDK auto-compacts when buffer is 80% full:
- Summarizes older messages
- Preserves key context (file contents, decisions)
- Seamless to the user — just keep chatting

---

## Tool Registration Strategy

The app registers tools that bridge iOS capabilities to the Copilot CLI:

### Layer 1: WebKitAgent Tools (built-in)
```swift
let webTools = WebAgentToolProvider(manager: webManager)
// Gives agent: web_agent(navigate, snapshot, click, type, download, upload)
```

### Layer 2: iOS-Native Tools (custom)
```swift
let iosTools: [ToolDefinition] = [
    // Camera
    ToolDefinition(name: "take_photo", description: "Capture photo with iPhone camera",
        handler: { _ in camera.capturePhotoBase64() }),
    
    // Voice
    ToolDefinition(name: "speak", description: "Read text aloud to user",
        handler: { args in voice.speak(args["text"]); return "Spoken" }),
    
    ToolDefinition(name: "listen", description: "Listen for user's voice input",
        handler: { args in return await voiceInput.listen(duration: 10) }),
    
    // Notifications
    ToolDefinition(name: "notify", description: "Send push notification to user",
        skipPermission: true,
        handler: { args in sendLocalNotification(args["message"]); return "Notified" }),
    
    // Clipboard
    ToolDefinition(name: "copy_to_clipboard", description: "Copy text to clipboard",
        handler: { args in UIPasteboard.general.string = args["text"]; return "Copied" }),
    
    // Local storage
    ToolDefinition(name: "save_note", description: "Save a note/file locally on iPhone",
        handler: { args in saveToDocuments(args["name"], args["content"]) }),
]
```

### Layer 3: Agent Overrides
Override built-in Copilot tools to use iOS capabilities:
```swift
ToolDefinition(
    name: "read_file",
    description: "Read a file — shows content in the app's file viewer",
    overridesBuiltInTool: true,
    handler: { args in
        let content = try readFile(args["path"])
        updateFileViewer(path: args["path"], content: content)  // show in UI
        return content
    }
)
```

### Combined Registration
```swift
let allTools = webTools.tools + iosTools + overrideTools
let session = try await client.createSession(config: SessionConfig(
    model: "gpt-4.1",
    tools: allTools,
    systemMessage: .append("""
        \(WebAgentToolProvider.skillPrompt)
        You are Neox, an AI dev assistant on iPhone. 
        You can browse the web, take photos, speak to the user, and listen.
        Use the browser to operate websites like GitHub, Vercel, etc.
    """)
))
```

---

## Streaming Architecture

Real-time UI updates as the agent works:

```swift
// Enable streaming
let session = try await client.createSession(config: SessionConfig(
    streaming: true,
    ...
))

// Wire up events to UI
await session.on(.assistantMessageDelta) { event in
    // Append text to chat bubble in real-time
    DispatchQueue.main.async { chatVM.appendDelta(event.deltaContent) }
}

await session.on(.toolExecutionStart) { event in
    // Show "Agent is using web_agent..." indicator
    DispatchQueue.main.async { chatVM.showToolUse(event.toolName) }
}

await session.on(.toolExecutionComplete) { event in
    // Show tool result (e.g., DOM snapshot, file content)
    DispatchQueue.main.async { chatVM.showToolResult(event) }
}

await session.on(.assistantReasoning) { event in
    // Show thinking indicator (collapsible)
    DispatchQueue.main.async { chatVM.showThinking(event.content) }
}

await session.on(.sessionIdle) { _ in
    // Re-enable input, hide progress
    DispatchQueue.main.async { chatVM.setIdle() }
}
```

---

## Permission Model

The app mediates between agent and user for sensitive operations:

```swift
let session = try await client.createSession(config: SessionConfig(
    onPermissionRequest: { request in
        switch request.kind {
        case "shell":
            // Show: "Agent wants to run: `rm -rf build/`  [Allow] [Deny]"
            return await showPermissionDialog(request)
        case "write":
            // Show: "Agent wants to modify: Package.swift  [Allow] [Deny]"
            return await showPermissionDialog(request)
        case "read":
            return .approved  // reading is safe
        default:
            return await showPermissionDialog(request)
        }
    }
))
```

### Permission UX
```
┌─────────────────────────────────┐
│ ⚠️ Agent requests permission    │
│                                 │
│ Run shell command:              │
│ ┌─────────────────────────────┐ │
│ │ npm install express         │ │
│ └─────────────────────────────┘ │
│                                 │
│      [Deny]    [Allow Once]     │
│               [Always Allow]    │
└─────────────────────────────────┘
```

---

## Model Selection

Dynamic model switching within the app:

```swift
// User picks model in settings or per-project
let models = ["gpt-4.1", "claude-sonnet-4.5", "gpt-4.1-mini", "o3"]

// Change mid-conversation
try await session.setModel("claude-sonnet-4.5", reasoningEffort: "high")
```

### Model Strategy
| Task | Best Model | Why |
|------|-----------|-----|
| Quick questions | gpt-4.1-mini | Fast, cheap |
| Code generation | gpt-4.1 / claude-sonnet-4.5 | Best coding |
| Complex reasoning | o3 | Deep thinking |
| Web automation | gpt-4.1 | Good tool use |

---

## Offline / Degraded Mode

When no connection to Copilot CLI:
1. **Queue messages** — type prompts, they send when reconnected
2. **Local features work** — camera, voice, file viewer, browser (manual mode)
3. **Apple Foundation Models** (iOS 26+) — basic on-device LLM for simple tasks
4. **Cached context** — previous session messages available offline

---

## Security

- All traffic over local network (TCP) or encrypted WebSocket (WSS)
- No credentials stored in app — auth is via Copilot CLI's GitHub token
- Permission system prevents destructive actions without approval
- File system access is on the Mac side, not the phone
- Option to pin to specific CLI instance (fingerprint verification)

---

## Connection Setup Flow (First Launch)

```
1. "Welcome to Neox"
2. "Start Copilot CLI on your Mac:"
   → Shows command: `copilot --headless --server --port 8080`
3. "Enter your Mac's IP or scan QR code"
   → Auto-discovers via Bonjour if available
4. [Connect] → ping test → "Connected! ✓"
5. "Choose your default model" → model picker
6. → Chat screen, ready to go
```

---

## MVP Backend (v0.1)

1. TCPTransport connection to Copilot CLI
2. Manual IP:port entry
3. Single session (no project management yet)
4. Streaming events → chat UI
5. WebKitAgent tools registered
6. Auto-approve all permissions (dev mode)

## v0.2
7. Session persistence (create, resume, list, delete)
8. Permission dialog UI
9. Model switching
10. Bonjour auto-discovery

## v0.3
11. WebSocket relay for remote access
12. Hybrid transport (TCP → WS fallback)
13. Multi-session (foreground/background)
14. Custom tool registration UI
