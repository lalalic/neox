# Brainstorm: iOS Agent-Powered Dev App

## The Building Blocks (copilot-ios SDK)

| Package | What It Does |
|---------|-------------|
| **CopilotSDK** | MCP client → connects to Copilot CLI as AI backend (WebSocket/TCP/Stdio). Sessions, streaming, tools, autonomous agent loop, image+file sending |
| **WebKitAgent** | In-app WKWebView with DOM snapshots, click/type/navigate — agent can operate any website |
| **AppAgent** | MCP server exposing the app's own UI via accessibility — external agents can control this app |
| **CameraKit** | Camera + voice + scene analysis, 32 tools, on-device Apple FM support |

---

## App Concept: **"Neox"** — AI Dev Studio on iPhone

A mobile-first development environment where you **talk to an agent** instead of writing code directly. The agent is the IDE — it operates websites (GitHub, Vercel, docs, Stack Overflow), writes code, deploys, and automates workflows, all from your phone.

### Core Screens

1. **Chat** — Primary interface. Text + voice input. Rich output (code blocks, previews, images, file trees). Streaming responses.
2. **Browser** — WebKitAgent-powered browser. Agent can operate it autonomously OR user browses manually and says "do X on this page."
3. **Projects** — List of sessions/projects. Resume previous agent conversations. Each project = a Copilot session with context.
4. **Files** — View/edit files the agent creates. Syntax-highlighted code viewer.

---

## Key Ideas

### 1. Voice-First Development
- Use CameraKit's `VoiceInput` to dictate prompts ("Create a landing page for my coffee shop")
- `VoiceOutput` reads back agent responses or code explanations
- Hands-free coding while commuting, walking, thinking

### 2. Agent-Operated Browser (WebKitAgent)
**Use cases:**
- "Go to my GitHub repo and create a new branch called feature/auth"
- "Open Vercel and deploy my latest push"
- "Find how to use Core Data SwiftUI and summarize the docs"
- "Go to my Supabase dashboard and create a users table"
- "Fill out the App Store Connect metadata for my app"
- "Navigate to Figma and describe the design on screen" (screenshot → agent analyzes)

Agent sees a DOM snapshot (like accessibility tree), clicks/types/navigates. User watches it happen in real-time in the embedded browser.

### 3. Website Automation Workflows (Saved Recipes)
- Predefined workflows: "Deploy to Vercel", "Create GitHub Issue", "Check CI status"
- User-created automations: "Every morning, check my GitHub notifications and summarize"
- Chain multiple sites: GitHub PR → CI logs → Slack notification

### 4. App Development via Agent
- Agent writes Swift/React Native/Flutter code in a remote workspace (Copilot CLI has file system access)
- User previews web apps in the built-in browser
- For native iOS: agent generates code → user copies to Xcode or pushes to GitHub
- Could integrate with GitHub Codespaces for full cloud dev

### 5. Self-Operating App (AppAgent)
- The app exposes its OWN UI as an MCP server
- External agents (VS Code, Claude Desktop) can control this app remotely
- "From my Mac, tell the iOS app to browse to X and capture a screenshot"
- Testing: agent can test the app it just built by operating it

### 6. Multi-Modal Input
- Send screenshots/photos to agent: "What's wrong with this UI?" (CopilotSDK's `sendWithImage`)
- Camera → agent sees what you see: "I'm looking at this error on my monitor, fix it"
- Send files for review: `sendWithFile`

---

## Architecture

```
┌─────────────────────────────────────────┐
│              Neox iOS App               │
│                                         │
│  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│  │   Chat   │  │ Browser  │  │ Files │ │
│  │  View    │  │(WebKit-  │  │ View  │ │
│  │          │  │  Agent)  │  │       │ │
│  └────┬─────┘  └────┬─────┘  └───┬───┘ │
│       │              │            │     │
│  ┌────┴──────────────┴────────────┴───┐ │
│  │        Agent Coordinator           │ │
│  │  (manages sessions, routes tools)  │ │
│  └────────────────┬───────────────────┘ │
│                   │                     │
│  ┌────────────────┴───────────────────┐ │
│  │          CopilotSDK               │ │
│  │  CopilotClient → CopilotSession  │ │
│  │  Transport: TCP/WebSocket/Stdio   │ │
│  └────────────────┬───────────────────┘ │
│                   │                     │
│  ┌──────┐  ┌──────┴─────┐  ┌─────────┐ │
│  │Camera│  │  WebKit    │  │  App    │ │
│  │ Kit  │  │  Agent     │  │  Agent  │ │
│  │      │  │  (tools)   │  │  (MCP)  │ │
│  └──────┘  └────────────┘  └─────────┘ │
└─────────────────┬───────────────────────┘
                  │ TCP/WebSocket
                  ▼
          Copilot CLI (backend)
          Running on Mac/server
```

## Agent Tool Integration

The app registers custom tools so the agent can:

| Tool | Purpose |
|------|---------|
| `browse_web` | Navigate WebKitAgent to URL, get DOM snapshot |
| `web_click` | Click element on web page |
| `web_type` | Type into web form field |
| `web_screenshot` | Screenshot current page for analysis |
| `show_preview` | Render HTML/web content in browser panel |
| `notify_user` | Push notification for long-running tasks |
| `speak` | Read response aloud |
| `listen` | Capture voice input |
| `capture_photo` | Use camera for visual input |
| `save_file` | Save to local project storage |

---

## Differentiators

| Feature | Why It Matters |
|---------|---------------|
| **Phone-native** | Dev from anywhere. No laptop needed for quick tasks |
| **Voice-first** | Accessible, hands-free, natural |
| **Web automation** | Agent can DO things, not just talk about them |
| **Self-automatable** | AppAgent makes it controllable from desktop tools |
| **Session persistence** | Pick up where you left off. Context survives |
| **Camera input** | Point at whiteboard sketch → agent builds it |

---

## MVP Scope (v0.1)

1. **Chat screen** — text input, streaming response, code blocks
2. **Connect to Copilot CLI** via TCP transport (local network)
3. **Browser tab** — WebKitAgent with agent-operable tools registered
4. **Voice input** — tap mic button, speech-to-text → send as prompt
5. **One workflow** — "Open [URL], snapshot, summarize content"

## v0.2
- Voice output (TTS for responses)
- Project/session management (list, resume, delete)
- File viewer for agent-created files
- Camera input (photo → send to agent)

## v0.3
- Saved automations / recipes
- AppAgent MCP server (externally controllable)
- Multi-agent: different models for different tasks
- Share results (export chat, screenshots)

---

## Name Ideas
- **Neox** — new + neo, futuristic dev tool
- **Pilot** — you're the pilot, agent is co-pilot
- **Forge** — building things
- **Dash** — quick, mobile, dashboard-like
- **Proxy** — agent acts as your proxy on the web
