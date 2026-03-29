# Deep Dive: Agent-Operated Browser (WebKitAgent)

## How It Works

WebKitAgent wraps WKWebView and exposes a **single tool** (`web_agent`) with sub-commands. The agent sees web pages as a DOM snapshot (like an accessibility tree) with refs (r0, r1, r2...), then clicks/types/navigates using those refs.

```
Agent sees:
  r0 [button] "Sign In"
  r1 [input type=text] placeholder="Email"
  r2 [input type=password] placeholder="Password"
  r3 [a] "Forgot password?"

Agent acts:
  web_agent(command: "type", ref: "r1", text: "user@email.com")
  web_agent(command: "type", ref: "r2", text: "••••••")
  web_agent(command: "click", ref: "r0")
```

### Sub-commands
| Command | Params | What It Does |
|---------|--------|-------------|
| `navigate` | url | Load page, wait for ready |
| `snapshot` | — | DOM → ref-tagged interactive elements |
| `click` | ref | Click element by ref |
| `type` | ref, text | Fill input field |
| `download` | ref or url | Save file (cookie-aware) |
| `upload` | ref, fileURL | Upload file to input |

---

## UX Design: The Browser Tab

### Dual Mode Browser

The browser tab operates in two modes:

**1. Manual Mode (User Browses)**
- Normal web browser. User navigates, taps, types.
- A floating "Ask Agent" button appears.
- Tap it → "What do you want me to do on this page?"
- Agent gets DOM snapshot of current page as context.

**2. Agent Mode (Agent Operates)**
- Agent navigates and interacts autonomously.
- User watches actions happen in real-time.
- Each action highlights the element being interacted with (visual feedback).
- "Pause" / "Stop" buttons to interrupt agent.
- Agent narrates what it's doing in a floating overlay.

### Visual Feedback System

```
┌─────────────────────────────────┐
│ ← → ↻  [github.com/user/repo] │  ← nav bar
├─────────────────────────────────┤
│                                 │
│  ┌──────────────────────┐       │
│  │  ✨ Clicking "Deploy" │       │  ← agent action overlay
│  └──────────────────────┘       │
│                                 │
│         ┌────────────┐          │
│         │  [Deploy]  │ ← glow  │  ← highlighted element
│         └────────────┘          │
│                                 │
├─────────────────────────────────┤
│ ● Agent operating...  [⏸ Pause]│  ← status bar
└─────────────────────────────────┘
```

- Elements being clicked/typed pulse with a highlight
- A small overlay shows what the agent is doing
- Status bar shows agent state (operating, waiting, done)

---

## Key Scenarios

### 1. GitHub Operations
```
User: "Create a new repo called my-app with a README"
Agent:
  → navigate github.com/new
  → snapshot → finds repo name input
  → type "my-app"
  → check "Add a README"
  → click "Create repository"
  → "Done! Created github.com/user/my-app"
```

### 2. Deploy to Vercel
```
User: "Deploy my latest commit"
Agent:
  → navigate vercel.com/dashboard
  → snapshot → finds project
  → click project → deployment page
  → click "Redeploy"
  → wait → snapshot → reads status
  → "Deployed! Live at my-app.vercel.app"
```

### 3. Research & Summarize
```
User: "Find the best SwiftUI navigation library on GitHub"
Agent:
  → navigate github.com/search?q=swiftui+navigation
  → snapshot → reads results
  → click top 3 results, reads READMEs
  → "Here are the top 3:
     1. NavigationStack+ (2.3k ★) — declarative routing...
     2. FlowStacks (1.8k ★) — coordinator pattern...
     3. Router (900 ★) — type-safe deep links..."
```

### 4. Fill Out Forms
```
User: "Submit my App Store metadata" (user already on App Store Connect)
Agent:
  → snapshot current page
  → finds form fields
  → type description, keywords, support URL
  → upload screenshots (via upload command)
  → click "Save"
```

### 5. Monitor & Report
```
User: "Check my CI status on GitHub Actions"
Agent:
  → navigate github.com/user/repo/actions
  → snapshot
  → "Latest run: ✅ Build passed (2m ago)
     Previous: ❌ Test failed — 3 tests in AuthTests.swift"
```

### 6. Download Assets
```
User: "Download free icons from Flaticon for a weather app"
Agent:
  → navigate flaticon.com
  → search "weather"
  → snapshot results
  → download sun.png, cloud.png, rain.png
  → "Downloaded 3 icons to Documents/WebKitAgent/"
```

---

## Authentication & Cookies

A critical advantage of using WKWebView: **the user is already logged in.**

- User logs into GitHub, Vercel, etc. manually in the browser tab
- Cookies persist in WKWebView's cookie store
- When agent operates, it inherits all auth sessions
- No API keys or OAuth flows needed — just browse and login once

### Cookie-Aware Downloads
WebKitAgent copies WKWebView cookies to URLSession for downloads, so authenticated downloads (private repos, premium content) just work.

### Session Management
- Long-press sites to see saved cookies
- "Log me into GitHub" → agent navigates to login, user types password, agent continues
- Clear cookies per site

---

## Integration with Chat

The browser and chat are deeply connected:

### Chat → Browser
- User types "go to github.com" in chat → browser navigates
- "Download the PDF from this page [URL]" → agent opens, downloads
- Agent shows browser content inline in chat (snapshot text, screenshots)

### Browser → Chat
- User browses to a page → taps "Ask Agent" → "What is this page about?"
- Long-press text on page → "Explain this code to me"
- Right-click image → "Describe this image"

### Split View (iPad)
- Chat on left, browser on right
- Agent operates browser while you watch and steer via chat
- Drag and drop between chat and browser

---

## Automation Recipes (Preview)

Save browser workflows for reuse:

```yaml
name: "Deploy to Vercel"
steps:
  - navigate: "https://vercel.com/dashboard"
  - snapshot: {}
  - click: {text: "{{project_name}}"}    # finds by text match
  - snapshot: {}
  - click: {text: "Redeploy"}
  - wait: 5
  - snapshot: {}
  - extract: {field: "status"}           # reads deployment status
params:
  project_name: "my-app"
```

Agent generates these from natural language: "Save this as a recipe" after completing a workflow.

---

## Technical Architecture

```swift
// In the app's agent coordinator
import WebKitAgent
import CopilotSDK

class AgentCoordinator: ObservableObject {
    let webManager = WebViewManager()
    let webTools: WebAgentToolProvider
    var session: CopilotSession?
    
    init() {
        webTools = WebAgentToolProvider(manager: webManager)
    }
    
    func connectAndSetup() async throws {
        let transport = TCPTransport(host: "192.168.1.x", port: 8080)
        let client = CopilotClient(transport: transport)
        try await client.start()
        
        session = try await client.createSession(config: SessionConfig(
            model: "gpt-4.1",
            tools: webTools.tools,
            systemMessage: .append(WebAgentToolProvider.skillPrompt),
            streaming: true
        ))
    }
}

// SwiftUI browser view
struct BrowserView: View {
    @StateObject var coordinator: AgentCoordinator
    
    var body: some View {
        WebAgentView(manager: coordinator.webManager)
            .overlay(alignment: .bottom) {
                AgentStatusBar(session: coordinator.session)
            }
    }
}
```

---

## MVP Browser Features (v0.1)

1. WebAgentView embedded in a tab
2. URL bar with manual navigation
3. Agent can call `web_agent` tool (navigate, snapshot, click, type)
4. Chat integration: "open [URL]" from chat

## v0.2
5. Visual feedback (element highlighting on agent actions)
6. Agent action overlay ("Clicking Deploy...")
7. "Ask Agent" floating button for manual-mode context
8. Download support

## v0.3
9. Upload support
10. Saved automation recipes
11. Split view (iPad)
12. Cookie/session management UI
