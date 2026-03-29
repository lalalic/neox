# Neox — Product Spec

## What Is Neox?

An iOS app that turns your iPhone into an AI-powered agent that works for you. Talk to it, point your camera at things, and let it operate websites, send emails, manage code, and automate tasks — even in the background.

**Backend**: GitHub Copilot CLI via CopilotSDK (no custom server).  
**SDK**: [copilot-ios](https://github.com/lalalic/copilot-ios) — CopilotSDK, WebKitAgent, AppAgent, CameraKit.

---

## Architecture

```
┌───────────────────────────────────────────────┐
│                 Neox (iPhone)                  │
│                                               │
│  ┌─────────┐ ┌─────────┐ ┌──────┐ ┌───────┐  │
│  │  Chat   │ │ Browser │ │Tasks │ │ Files │  │
│  │  View   │ │(WebKit  │ │Queue │ │ View  │  │
│  │         │ │ Agent)  │ │      │ │       │  │
│  └────┬────┘ └────┬────┘ └──┬───┘ └───┬───┘  │
│       └───────────┼─────────┼─────────┘       │
│                   │         │                  │
│          ┌────────┴─────────┴───────┐          │
│          │    Agent Coordinator     │          │
│          │  sessions, tools, events │          │
│          └────────────┬─────────────┘          │
│                       │                        │
│  ┌────────┐ ┌─────────┴──────┐ ┌───────────┐  │
│  │Camera  │ │  CopilotSDK   │ │  AppAgent  │  │
│  │Kit     │ │  (TCP/WS)     │ │  (MCP svr) │  │
│  │voice+  │ │  JSON-RPC ────┼─┼──────────┐ │  │
│  │camera  │ └───────────────┘ │  remote   │ │  │
│  └────────┘                   │  control  │ │  │
│                               └──────────┘  │  │
└────────────────────┬────────────────────────┘  │
                     │ TCP / WebSocket            │
                     ▼                            │
             Copilot CLI (Mac)                    │
             ├── LLM (GPT-4.1, Claude, etc.)     │
             ├── File system                      │
             ├── Terminal                         │
             └── MCP servers                      │
```

---

## Core Features

### F1: Chat Interface
- Text + voice input
- Streaming assistant responses (deltas)
- Rich content: code blocks, images, file previews
- Tool use indicators ("Agent is browsing github.com...")
- Thinking/reasoning display (collapsible)
- Multi-modal: attach photo, file, voice note to prompt

### F2: Agent-Operated Browser
- Embedded WKWebView via WebKitAgent
- Single `web_agent` tool: navigate, snapshot, click, type, download, upload
- **Manual mode**: user browses, taps "Ask Agent" for context-aware help
- **Agent mode**: autonomous operation with visual feedback (element highlighting)
- Cookie persistence — user logs in once, agent inherits auth
- URL bar, back/forward, reload

### F3: Task Queue (Background Agent)
- Create scheduled/recurring/triggered tasks
- Tasks execute via Mac-side Copilot CLI (always-on) or iOS BGProcessingTask
- Results delivered as notifications with approve/edit/cancel actions
- Trust levels: ask always → ask for writes → fully autonomous
- Audit log of all background actions

### F4: Voice I/O
- Mic button: speech-to-text via CameraKit VoiceInput → send as prompt
- TTS: agent speaks responses via VoiceOutput
- Conversational mode: continuous listen/respond loop
- Siri Shortcuts: "Hey Siri, ask Neox to..."

### F5: Camera Input
- Take photo → send with prompt ("What's wrong with this UI?")
- Scene analysis (CameraKit SceneAnalyzer) pre-processes before sending to LLM
- Use cases: whiteboard → code, error on screen → fix, product → landing page

### F6: Project Management
- Each project = a CopilotSession with persistent context
- Create, resume, list, delete sessions
- Per-project model selection
- Infinite sessions (auto-compaction, never run out of context)

### F7: Self-Operating (AppAgent)
- MCP server exposes app UI via accessibility APIs
- External agents (VS Code, Claude Desktop) can control Neox remotely
- Used for automated testing (agent tests its own UI)
- Commands: snapshot, tap, type, swipe, find, screenshot

### F8: File Viewer
- View files created/modified by the agent
- Syntax-highlighted code display
- Agent can override `read_file` to show in-app viewer

---

## Tools Registered with CopilotSDK

### WebKitAgent Tools (built-in)
| Tool | Sub-commands |
|------|-------------|
| `web_agent` | navigate, snapshot, click, type, download, upload |

### iOS-Native Tools (custom)
| Tool | Purpose |
|------|---------|
| `take_photo` | Capture photo → base64 |
| `speak` | TTS output to user |
| `listen` | Speech recognition input |
| `notify` | Local notification |
| `copy_to_clipboard` | Copy result to clipboard |
| `save_note` | Save file to local storage |
| `show_preview` | Render HTML in browser tab |

### System Message
```
WebAgentToolProvider.skillPrompt + 
"You are Neox, an autonomous AI assistant on iPhone.
 You can browse the web, take photos, speak, listen, and manage tasks.
 Use the browser to operate websites. Use voice for hands-free interaction.
 When given a background task, use send_response to report results."
```

---

## Connection Setup

1. First launch: "Start Copilot CLI on your Mac" → shows command
2. Enter Mac IP:port or auto-discover via Bonjour (_copilot._tcp)
3. Ping test → connected
4. Choose default model → ready

### Transports
| Transport | Use Case |
|-----------|----------|
| TCP | Local dev (same WiFi, low latency) |
| WebSocket | Remote access (relay server) |
| Hybrid | TCP first → WS fallback |

---

## Permission Model

| Action | Default |
|--------|---------|
| Read websites / files | Auto-approve |
| Write files | Ask once, remember |
| Shell commands | Show command, ask |
| Post to social / send email | Ask always |
| Deploy | Ask always |
| Delete anything | Ask always |

Configurable trust levels per-project.

---

## iOS Background Strategy

| iOS Mode | Duration | Used For |
|----------|----------|---------|
| BGProcessingTask | Minutes | Longer agent tasks |
| Background Fetch | 30s | Check for results, quick web ops |
| Silent Push | 30s | Server-triggered tasks |
| Background URL Session | Unlimited | File uploads/downloads |
| Live Activity | Ongoing | Show task progress on lock screen |
| Siri Shortcuts | On demand | Hands-free agent commands |

**Primary strategy**: Mac-side Copilot CLI runs heavy tasks 24/7. Phone dispatches, monitors, and shows results.

---

## Test Strategy (TDD + AppAgent)

### Unit Tests
- Swift Testing / XCTest for all view models, coordinators, tool handlers
- Mock CopilotSDK transport for offline testing
- Test tool registration, event handling, session management

### UI Tests (via AppAgent)
- AppAgent MCP server runs inside the app
- External agent (from VS Code) drives the UI:
  1. `snapshot` → see current screen
  2. `tap`/`type` → interact
  3. `snapshot` → verify result
- No manual testing — agent automates all UI verification
- Test scripts as repeatable agent prompts

### Integration Tests
- Real CopilotSDK connection to Copilot CLI
- End-to-end: send prompt → receive response → verify in chat
- WebKitAgent: navigate → snapshot → verify DOM content

### TDD Loop
```
1. Write test (XCTest/Swift Testing)
2. Run test → RED
3. Implement minimal code
4. Run test → GREEN
5. Refactor
6. UI test via AppAgent to verify on device
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI Framework | SwiftUI |
| Language | Swift 6.0 |
| Min iOS | 18.0 |
| Agent SDK | copilot-ios (CopilotSDK, WebKitAgent, AppAgent, CameraKit) |
| Backend | Copilot CLI (headless, TCP server) |
| Testing | XCTest, Swift Testing, AppAgent MCP |
| Background | BGTaskScheduler, Live Activities |
| Voice | AVFoundation (Speech, AVSpeech) |
| Camera | AVFoundation, Vision |

---

## MVP Scope (v0.1)

### Must Have
- [ ] Chat screen: text input, streaming response, code blocks  
- [ ] TCP connection to Copilot CLI  
- [ ] WebKitAgent browser tab (navigate, snapshot, click, type)  
- [ ] Voice input (mic button → speech-to-text → prompt)  
- [ ] AppAgent MCP server for automated testing  
- [ ] Single session (no project management)  
- [ ] Permission dialog (approve/deny)  

### Nice to Have (v0.1)
- [ ] Voice output (TTS)
- [ ] Photo attachment
- [ ] URL bar in browser

### Out of Scope (v0.1)
- Background tasks / scheduling
- Project management (multi-session)  
- Siri Shortcuts
- Live Activities
- File viewer
- Automation recipes
- Model switching UI

---

## Milestones

### M1: Foundation (Week 1-2)
- Xcode project with copilot-ios dependency
- AgentCoordinator: connect via TCP, create session
- AppAgent MCP server running (for testing)
- First TDD tests passing

### M2: Chat (Week 2-3)
- Chat view model with streaming
- SwiftUI chat UI (bubbles, code blocks)
- Send text prompt → receive response
- Tool use indicators

### M3: Browser (Week 3-4)
- WebKitAgent integration
- Browser tab with URL bar
- Agent operates browser from chat ("go to github.com")
- Visual feedback for agent actions

### M4: Voice (Week 4-5)
- Mic button → speech-to-text
- TTS for agent responses
- Photo attachment (camera → send to agent)

### M5: Polish & Release (Week 5-6)
- Permission UI
- Connection management (reconnect, status indicator)
- Error handling
- TestFlight beta

---

## File Structure (Planned)

```
Neox/
├── Neox.xcodeproj
├── Neox/
│   ├── App/
│   │   ├── NeoxApp.swift
│   │   └── ContentView.swift          # Tab container
│   ├── Agent/
│   │   ├── AgentCoordinator.swift     # CopilotSDK session management
│   │   ├── ConnectionManager.swift    # Transport, reconnect logic
│   │   ├── ToolRegistry.swift         # Register iOS-native tools
│   │   └── PermissionHandler.swift    # Approve/deny dialog
│   ├── Chat/
│   │   ├── ChatView.swift
│   │   ├── ChatViewModel.swift
│   │   ├── MessageBubble.swift
│   │   └── InputBar.swift             # Text + mic + photo buttons
│   ├── Browser/
│   │   ├── BrowserView.swift
│   │   ├── BrowserViewModel.swift
│   │   └── AgentOverlay.swift         # Visual feedback overlay
│   ├── Tasks/
│   │   ├── TaskQueueView.swift
│   │   └── TaskQueueViewModel.swift
│   ├── Voice/
│   │   ├── VoiceInputManager.swift
│   │   └── VoiceOutputManager.swift
│   └── Testing/
│       └── AppAgentSetup.swift        # MCP server for UI testing
├── NeoxTests/
│   ├── AgentCoordinatorTests.swift
│   ├── ChatViewModelTests.swift
│   ├── ConnectionManagerTests.swift
│   └── ToolRegistryTests.swift
└── Package.swift / SPM dependencies
```

---

## References

- [Brainstorm: Main concept](.github/brainstorm-copilot-app.md)
- [Brainstorm: Multi-modal input](.github/brainstorm-multimodal.md)
- [Brainstorm: Browser / WebKitAgent](.github/brainstorm-browser.md)
- [Brainstorm: Backend architecture](.github/brainstorm-backend.md)
- [Brainstorm: Background agent](.github/brainstorm-background-agent.md)
- [copilot-ios SDK](https://github.com/lalalic/copilot-ios)
