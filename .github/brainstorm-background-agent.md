# Deep Dive: Autonomous Background Agent

## The Vision

Neox isn't just an app you open and use — it's an **always-running AI assistant** that works on your behalf even when you're not looking. You tell it "post a summary of my day on Twitter every evening" or "reply to GitHub issues tagged 'bug' with a triage response" and it just does it.

---

## iOS Background Execution: What's Possible

iOS is restrictive about background execution, but there ARE viable paths:

### Tier 1: Native Background Modes (Reliable)

| Mode | Duration | Use Case |
|------|----------|----------|
| **Background Fetch** | ~30 seconds | Check for new tasks, quick web operations |
| **Silent Push Notifications** | ~30 seconds | Server triggers: "new GitHub issue → reply" |
| **BGProcessingTask** | Up to minutes (at system discretion) | Longer tasks: compose email, batch replies |
| **Background URL Session** | Unlimited for transfers | Upload/download files in background |
| **VoIP Push** (with CallKit) | Keep-alive | Persistent connection to Copilot CLI |
| **Location Updates** | Ongoing | "When I arrive at office, check my PRs" |

### Tier 2: Creative Approaches

| Approach | How | Trade-off |
|---------|-----|---------|
| **Live Activity** | Persistent UI on lock screen, refreshes regularly | Limited to status display, but can wake app |
| **WidgetKit Timeline** | Widgets refresh periodically, can trigger work | Limited execution time |
| **Local Notifications + Action** | Agent schedules notification → user taps → executes | Requires user tap |
| **Shortcuts & Automations** | Siri Shortcuts triggered by time/location/NFC | Powerful, system-level |
| **Always-On Server** | Copilot CLI on Mac does background work, phone is just the UI | Most reliable |

### Tier 3: The Hybrid Model (Recommended)

```
┌─────────────────────────────────────────────────┐
│                 HYBRID ARCHITECTURE              │
│                                                  │
│  iPhone (Neox)              Mac (Copilot CLI)    │
│  ┌──────────┐               ┌──────────────┐    │
│  │ Foreground│──── TCP ─────│ Agent Loop   │    │
│  │ Chat/     │              │              │    │
│  │ Browser   │              │ Autonomous   │    │
│  └──────────┘              │ execution    │    │
│                             │              │    │
│  ┌──────────┐              │ Scheduled    │    │
│  │Background│←─ Push ──────│ tasks        │    │
│  │ Fetch    │              │              │    │
│  │ (30s)    │──Results──→  │ Web scraping │    │
│  └──────────┘              │ via headless │    │
│                             │ browser      │    │
│  ┌──────────┐              └──────────────┘    │
│  │ Siri     │                                  │
│  │Shortcuts │─"Hey Siri, ask Neox to..."       │
│  └──────────┘                                  │
└─────────────────────────────────────────────────┘
```

**Key insight:** The Mac-side Copilot CLI can run 24/7. The phone is the command center that dispatches, monitors, and receives results. Heavy background work happens on the Mac.

---

## Task Queue System

### How It Works

1. User creates a task: "Reply to all new GitHub issues every hour"
2. Task is stored locally AND sent to Mac-side agent
3. **If phone is foreground**: agent executes via WebKitAgent (visible)
4. **If phone is background**: Mac-side agent executes via headless tools
5. **Results**: pushed to phone via notification / shown next time app opens

### Task Types

```swift
struct AgentTask: Codable, Identifiable {
    let id: UUID
    var name: String
    var prompt: String                    // What to tell the agent
    var schedule: TaskSchedule            // When to run
    var status: TaskStatus                // pending, running, completed, failed
    var requiresWebKit: Bool             // Needs browser?
    var requiresUserApproval: Bool       // Ask before executing?
    var results: [TaskResult]            // History of executions
}

enum TaskSchedule {
    case once                             // Run now
    case recurring(interval: TimeInterval) // Every N minutes/hours
    case cron(String)                     // Cron expression
    case trigger(TaskTrigger)             // Event-based
    case location(CLLocation, radius: Double) // Geofence
}

enum TaskTrigger {
    case pushNotification                 // Server says "go"
    case newEmail                         // Mail triggers it
    case timeOfDay(hour: Int, minute: Int) // Daily at time
    case appLaunch                        // Every time app opens
    case shortcut                         // Siri Shortcut triggers
}
```

### Task Examples

| Task | Schedule | Execution |
|------|----------|-----------|
| "Summarize my GitHub notifications" | Every morning 8am | BGProcessingTask → WebKitAgent |
| "Reply to new issues tagged 'question'" | Push notification when issue created | Silent push → 30s background |
| "Post my daily commit summary to Slack" | Daily at 6pm | Mac-side agent (headless) |
| "Check if my deployment is healthy" | Every 30 minutes | Background fetch |
| "When I arrive at office, pull latest PRs" | Geofence trigger | Location background mode |
| "Send standup email with yesterday's work" | Weekdays 9:15am | BGProcessingTask |
| "Download new design assets from Figma" | Manual trigger from widget | Background URL session |

---

## Autonomous Agent Patterns

### Pattern 1: Email Agent
```
User: "Draft a response to the latest email from John about the API deadline"

Agent:
  → Opens Mail (via WebKitAgent or URL scheme)
  → Finds John's email
  → Reads content
  → Drafts response considering context
  → Shows draft to user: "Here's my draft. Send it?"
  → User: "Add a note about the database migration"
  → Agent revises
  → Sends
```

### Pattern 2: Social Media Agent
```
User: "Post a thread on Twitter about what I built today"

Agent:
  → Checks recent git commits (via Copilot CLI)
  → Summarizes the work
  → Drafts a thread: "🧵 Today I built..."
  → Web agent navigates to twitter.com/compose
  → Types thread content
  → Shows preview: "Post this thread?"
  → User approves
  → Posts

Recurring version:
  "Every Friday at 5pm, post a weekly dev update thread"
  → Agent runs on schedule, drafts, notifies user for approval
```

### Pattern 3: Code Review Bot
```
User: "Monitor my repo and auto-review new PRs"

Agent (runs on Mac):
  → Polls GitHub for new PRs (or webhook trigger)
  → When new PR found:
    → Reads diff
    → Generates review comments
    → Sends notification to phone: "New PR #42 reviewed. 3 suggestions."
    → User can approve/modify review from notification
    → Agent posts review on GitHub
```

### Pattern 4: Research Agent
```
User: "Research the best database for my project, email me a comparison"

Agent (long-running on Mac):
  → Browses documentation sites
  → Reads benchmarks, comparisons, HN discussions
  → Compiles findings
  → Drafts email with comparison table
  → Notifies user: "Research complete. Review email draft?"
```

### Pattern 5: Photo Agent
```
User: "Take a photo every hour and create a timelapse"

Agent (iOS, needs foreground occasionally):
  → Schedules BGProcessingTask every hour
  → Each execution: briefly activates camera, captures frame
  → Stores frames
  → At end of day: compiles timelapse video
  → Notifies user with result

User: "When I receive a package (doorbell rings), take a photo"
  → Listens for doorbell sound pattern via mic
  → Captures photo
  → Sends notification with photo
```

---

## Siri Shortcuts Integration

Register custom Siri Shortcuts for hands-free agent commands:

```swift
import AppIntents

struct AskNeoxIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Neox"
    
    @Parameter(title: "Prompt")
    var prompt: String
    
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = try await AgentCoordinator.shared.quickAsk(prompt)
        return .result(dialog: "\(response)")
    }
}

// "Hey Siri, ask Neox to check my GitHub notifications"
// "Hey Siri, ask Neox what's on my calendar today"
// "Hey Siri, tell Neox to deploy my app"
```

### Shortcut Automations
| Trigger | Automation |
|---------|-----------|
| Time of day | "Every morning: summarize GitHub + email digest" |
| Arrive at location | "At office: check PR status, start dev server" |
| Connect to CarPlay | "In car: read pending messages aloud" |
| NFC tag | "Tap desk tag: start work session, open project" |
| Focus mode | "Work Focus on: mute notifications, batch emails" |
| Low battery | "Pause non-essential background tasks" |

---

## Live Activities & Dynamic Island

### Running Task Display
```
┌─────────────────────────────────┐
│ 🤖 Neox: Reviewing PR #42...   │  ← Dynamic Island (compact)
└─────────────────────────────────┘

┌─────────────────────────────────┐
│ 🤖 Neox Agent                   │
│                                 │  ← Lock Screen Live Activity
│ Reviewing PR #42: auth-refactor │
│ ████████░░ 80%  •  3 comments  │
│                                 │
│ [View] [Approve] [Stop]        │
└─────────────────────────────────┘
```

- Shows current agent task on lock screen
- Quick actions without opening the app
- Updates as agent progresses

### Widget
```
┌─────────────────┐
│ 🤖 Neox         │
│                 │
│ ✅ PR reviewed  │  ← Small widget: last action
│ 📬 3 new issues │
│ 🚀 Deploy OK   │
│                 │
│ [Ask Agent]     │
└─────────────────┘
```

---

## Approval Flow

For actions that modify external state, agent asks for approval:

### Notification-Based Approval
```
┌─────────────────────────────────┐
│ 🤖 Neox Agent                   │
│                                 │
│ Ready to post on Twitter:       │
│ "🧵 This week I shipped..."    │
│                                 │
│ [Approve] [Edit] [Cancel]       │
└─────────────────────────────────┘
```

- **Approve**: Agent proceeds
- **Edit**: Opens app to the draft
- **Cancel**: Agent stops

### Trust Levels
```swift
enum TrustLevel {
    case askAlways        // Approve every action
    case askForWrites     // Auto-approve reads, ask for writes
    case askForDangerous  // Auto-approve most, ask for deletes/deploys
    case fullyAutonomous  // YOLO mode — agent does everything
}
```

---

## Implementation: Background Task Manager

```swift
import BackgroundTasks

class BackgroundTaskManager {
    static let fetchIdentifier = "com.neox.agent.fetch"
    static let processingIdentifier = "com.neox.agent.processing"
    
    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.fetchIdentifier,
            using: nil
        ) { task in
            self.handleFetch(task as! BGAppRefreshTask)
        }
        
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil
        ) { task in
            self.handleProcessing(task as! BGProcessingTask)
        }
    }
    
    func handleFetch(_ task: BGAppRefreshTask) {
        // Quick tasks: check notifications, poll for results
        Task {
            let coordinator = AgentCoordinator.shared
            
            // Check Mac-side agent for completed tasks
            let results = try await coordinator.checkPendingResults()
            
            // Show notifications for completed tasks
            for result in results {
                showLocalNotification(result)
            }
            
            task.setTaskCompleted(success: true)
            scheduleNextFetch()
        }
    }
    
    func handleProcessing(_ task: BGProcessingTask) {
        // Longer tasks: web operations, email composition
        Task {
            let pendingTasks = TaskStore.shared.dueNow()
            
            for agentTask in pendingTasks {
                if task.expirationHandler != nil { break }  // system wants us to stop
                try await executeTask(agentTask)
            }
            
            task.setTaskCompleted(success: true)
        }
    }
}
```

---

## Mac-Side Agent (Always-On)

The most reliable background execution: let the Mac handle it.

```swift
// On iPhone: dispatch task to Mac
try await session.send(prompt: """
    BACKGROUND TASK: Every hour, check github.com/user/repo/issues for new issues.
    For each new issue tagged 'question':
    1. Read the issue content
    2. Draft a helpful response
    3. Save the draft to ~/neox-drafts/{issue-number}.md
    4. Send a notification via the notify tool
    
    Run this continuously. Use send_response to report each completed issue.
""")

// Mac-side agent runs in loop mode, never stops
// Uses file system + web tools (headless) to do the work
// Sends results back via send_response tool → phone gets notification
```

### Mac Agent Dashboard (Web UI)
Copilot CLI could serve a simple web dashboard:
- View running tasks
- See agent logs
- Pause/resume tasks
- Accessible from phone's browser too

---

## Privacy & Safety

### Guardrails for Autonomous Actions
1. **Rate limiting** — Max N actions per hour per service (e.g., max 10 tweets/day)
2. **Content review** — Agent drafts are held for review before posting publicly
3. **Rollback** — Agent logs everything, can undo (delete tweet, edit comment)
4. **Kill switch** — One-tap stop all background tasks
5. **Audit log** — Full history of what agent did while backgrounded
6. **Sandbox** — Web operations in WebKitAgent use separate cookie containers per task

### What Needs Approval (Defaults)
| Action | Default |
|--------|---------|
| Read websites | Auto-approve |
| Send email | Ask always |
| Post on social media | Ask always |
| GitHub comment/review | Ask for writes |
| File downloads | Auto-approve |
| Deploy | Ask always |
| Delete anything | Ask always |
| API calls | Ask for writes |

---

## MVP Background Features (v0.1)

1. **Task queue UI** — create, view, delete tasks
2. **Simple scheduling** — "run at [time]" via BGProcessingTask
3. **Notification for results** — agent completes task → notification
4. **Mac-side delegation** — send long-running prompts to Copilot CLI loop mode

## v0.2
5. Siri Shortcuts integration (3-5 common intents)
6. Live Activity for running tasks
7. Approval flow via notification actions
8. Recurring tasks (cron-like)

## v0.3
9. Location-based triggers
10. Widget with task status
11. Trust levels configuration
12. Full audit log
13. Mac agent dashboard
