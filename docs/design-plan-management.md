# Design: Plan Management System (iOS BGTask-Driven)

> **Status:** Refined — decisions confirmed, ready for final review before coding  
> **Priority:** P1  
> **Date:** 2025-07-17 (refined 2025-07-17)  
> **Prior Art:** [brainstorm-background-agent.md](../../.github/brainstorm-background-agent.md)

---

## Decisions (User Confirmed)

- **Execution Driver**: **iOS BGTaskScheduler** — device owns scheduling, not server
- **Relay Role**: Session host only — runs CLI when iOS triggers it, no server-side cron
- **Architecture**: iOS initiates → relay executes → iOS collects result

---

## 1. Problem Statement

Users want Neox to execute tasks autonomously — scheduled posts, recurring checks, monitoring, etc. We need a system that:

1. Lets users **create plans** (named tasks with prompts + schedules)
2. **Executes plans** via iOS BGTaskScheduler triggering relay sessions
3. Shows **results/status** on the phone
4. Supports **approval flows** for destructive/sensitive actions

---

## 2. Architecture: iOS BGTask-Driven

**Key choice:** iOS owns the schedule. When a BGTask fires, iOS wakes the app, connects to relay, runs the plan session, collects the result, and persists it locally.

```
┌───────────────────────────────────────────┐
│  iOS App (Neox)                           │
│                                           │
│  ┌─────────────────────────────────────┐  │
│  │ PlanScheduler (BGTaskScheduler)     │  │
│  │  └─ register BGProcessingTask       │  │
│  │  └─ register BGAppRefreshTask       │  │
│  │  └─ schedule tasks per plan         │  │
│  ├─────────────────────────────────────┤  │
│  │ PlanStore (local, SwiftData/JSON)   │  │
│  │  └─ plan definitions                │  │
│  │  └─ execution history               │  │
│  │  └─ results + cost tracking         │  │
│  ├─────────────────────────────────────┤  │
│  │ PlanManagerView                     │  │
│  │  └─ create/edit/view plans          │  │
│  │  └─ execution history               │  │
│  │  └─ manual trigger                  │  │
│  └─────────────────────────────────────┘  │
└──────────┬────────────────────────────────┘
           │ BGTask fires →
           │ WebSocket connect + session.create + send
           ▼
┌───────────────────────────────────────────┐
│  Relay Server (Node.js, always-on)        │
│  └─ receives session.create request       │
│  └─ spawns Copilot CLI                    │
│  └─ runs plan prompt in session           │
│  └─ streams events back to iOS            │
│  └─ NO scheduling logic, no cron          │
└──────────┬────────────────────────────────┘
           │ stdin/stdout
           ▼
┌───────────────────────────────────────────┐
│  Copilot CLI                              │
│  └─ session.create + send                 │
│  └─ assistant.usage events for cost       │
└───────────────────────────────────────────┘
```

### Why iOS BGTask, not server-driven?

| | iOS BGTask | Server cron |
|---|---|---|
| Simplicity | Plan data lives on device only | Need server storage + sync |
| Privacy | Prompts/results never leave device | Server stores all plan data |
| Reliability | Limited by iOS scheduling | 24/7 if server is up |
| Offline | Won't run if relay unreachable | Runs regardless |
| Complexity | ~200 LOC iOS | ~400 LOC relay + ~200 LOC iOS |

**Trade-off accepted:** Plans may be delayed by iOS system scheduling (can be minutes late). This is fine for digest/monitoring use cases. For time-critical tasks, user can trigger manually.

---

## 3. iOS Background Execution

### 3.1 BGTaskScheduler Setup

```swift
// In AppDelegate / App init
BGTaskScheduler.shared.register(
    forTaskWithIdentifier: "com.neox.plan.process",
    using: nil
) { task in
    PlanExecutor.shared.handleBGProcessingTask(task as! BGProcessingTask)
}

BGTaskScheduler.shared.register(
    forTaskWithIdentifier: "com.neox.plan.refresh",
    using: nil
) { task in
    PlanExecutor.shared.handleBGRefreshTask(task as! BGAppRefreshTask)
}
```

### 3.2 Info.plist

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.neox.plan.process</string>
    <string>com.neox.plan.refresh</string>
</array>
<key>UIBackgroundModes</key>
<array>
    <string>processing</string>
    <string>fetch</string>
</array>
```

### 3.3 Task Types

| Task | Type | Duration | Use |
|------|------|----------|-----|
| `com.neox.plan.process` | BGProcessingTask | Up to minutes | Full plan execution (connect relay, run session, collect result) |
| `com.neox.plan.refresh` | BGAppRefreshTask | ~30 seconds | Check if any plan is due, schedule processing task |

### 3.4 Scheduling Flow

```swift
/// When a plan is created or updated, schedule its next execution.
func schedulePlan(_ plan: Plan) {
    let request = BGProcessingTaskRequest(identifier: "com.neox.plan.process")
    request.requiresNetworkConnectivity = true  // Need relay
    request.requiresExternalPower = false
    
    // Set earliest begin date based on schedule
    switch plan.schedule {
    case .interval(let seconds):
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(seconds))
    case .cron(let nextDate):
        request.earliestBeginDate = nextDate
    case .once(let at):
        request.earliestBeginDate = at
    case .manual:
        return  // Don't schedule
    }
    
    do {
        try BGTaskScheduler.shared.submit(request)
    } catch {
        print("Failed to schedule plan \(plan.id): \(error)")
    }
}
```

---

## 4. Data Model

### 4.1 Plan (Device-Local)

```swift
struct Plan: Codable, Identifiable {
    let id: String  // UUID
    var name: String
    var prompt: String
    var schedule: PlanSchedule
    var model: String
    var enabled: Bool
    var requiresApproval: Bool
    var maxTokenBudget: Int  // Stop if exceeded
    var tools: [String]  // e.g., ["web_agent"]
    var createdAt: Date
    var updatedAt: Date
}

enum PlanSchedule: Codable {
    case manual
    case once(at: Date)
    case interval(seconds: Int)
    case cron(expression: String, timezone: String)
    
    /// Calculate next fire date.
    func nextFireDate(after: Date = Date()) -> Date? {
        switch self {
        case .manual: return nil
        case .once(let at): return at > after ? at : nil
        case .interval(let seconds): return after.addingTimeInterval(TimeInterval(seconds))
        case .cron(let expr, let tz): return CronParser.nextDate(expr, timezone: tz, after: after)
        }
    }
}
```

### 4.2 Execution Record (Device-Local)

```swift
struct PlanExecution: Codable, Identifiable {
    let id: String  // UUID
    let planId: String
    let startedAt: Date
    var completedAt: Date?
    var status: ExecutionStatus
    var result: String?  // Markdown response from assistant
    var tokensUsed: TokenUsage?
    var cost: Double?
    var error: String?
    
    enum ExecutionStatus: String, Codable {
        case running, completed, failed, cancelled, awaitingApproval
    }
    
    struct TokenUsage: Codable {
        var promptTokens: Int
        var completionTokens: Int
    }
}
```

---

## 5. Core Components

### 5.1 PlanStore — Local Persistence

```swift
@MainActor
class PlanStore: ObservableObject {
    @Published var plans: [Plan] = []
    
    private let storePath: URL  // ~/Documents/plans.json
    
    func load() { /* Read from storePath */ }
    func save() { /* Write to storePath */ }
    
    func createPlan(_ plan: Plan) {
        plans.append(plan)
        save()
        PlanExecutor.shared.schedulePlan(plan)
    }
    
    func updatePlan(_ plan: Plan) {
        if let idx = plans.firstIndex(where: { $0.id == plan.id }) {
            plans[idx] = plan
            save()
            PlanExecutor.shared.reschedulePlan(plan)
        }
    }
    
    func deletePlan(_ id: String) {
        plans.removeAll { $0.id == id }
        save()
        PlanExecutor.shared.cancelPlan(id)
    }
    
    func addExecution(_ exec: PlanExecution) { /* Append to history file */ }
    func getHistory(for planId: String) -> [PlanExecution] { /* Read history */ }
}
```

### 5.2 PlanExecutor — BGTask Handler + Session Runner

```swift
class PlanExecutor {
    static let shared = PlanExecutor()
    
    private let planStore: PlanStore
    
    /// Called by BGProcessingTask handler.
    func handleBGProcessingTask(_ task: BGProcessingTask) {
        // Find the next due plan
        let duePlans = planStore.plans.filter { $0.enabled && isDue($0) }
        guard let plan = duePlans.first else {
            task.setTaskCompleted(success: true)
            scheduleNextCheck()
            return
        }
        
        let execTask = Task {
            await executePlan(plan)
        }
        
        task.expirationHandler = {
            execTask.cancel()
        }
        
        Task {
            await execTask.value
            task.setTaskCompleted(success: true)
            
            // Schedule next execution for this plan
            if plan.schedule.nextFireDate() != nil {
                schedulePlan(plan)
            }
        }
    }
    
    /// Execute a plan: connect to relay, run session, collect result.
    func executePlan(_ plan: Plan) async {
        let execution = PlanExecution(
            id: UUID().uuidString,
            planId: plan.id,
            startedAt: Date(),
            status: .running
        )
        planStore.addExecution(execution)
        
        do {
            // 1. Connect to relay (reuse CopilotClient)
            let client = try await CopilotClient(url: relayURL)
            
            // 2. Create session with plan's model
            let session = try await client.createSession(model: plan.model)
            
            // 3. Subscribe to events
            var resultText = ""
            var totalTokens = PlanExecution.TokenUsage(promptTokens: 0, completionTokens: 0)
            
            await session.on(.assistantMessage) { event in
                if let text = event.data.stringValue {
                    resultText += text
                }
            }
            
            await session.on(.assistantUsage) { event in
                // Accumulate tokens
                if let pt = event.data["prompt_tokens"].intValue {
                    totalTokens.promptTokens += pt
                }
                if let ct = event.data["completion_tokens"].intValue {
                    totalTokens.completionTokens += ct
                }
            }
            
            // 4. Send plan prompt
            try await session.send(plan.prompt)
            
            // 5. Wait for idle (turn complete)
            try await session.waitForIdle(timeout: 120)
            
            // 6. Record result
            var completed = execution
            completed.status = .completed
            completed.completedAt = Date()
            completed.result = resultText
            completed.tokensUsed = totalTokens
            planStore.addExecution(completed)
            
            // 7. Post local notification
            postCompletionNotification(plan: plan, result: resultText)
            
            // 8. Disconnect
            try await session.disconnect()
            
        } catch {
            var failed = execution
            failed.status = .failed
            failed.error = error.localizedDescription
            failed.completedAt = Date()
            planStore.addExecution(failed)
        }
    }
    
    /// Post a local notification with plan result summary.
    private func postCompletionNotification(plan: Plan, result: String) {
        let content = UNMutableNotificationContent()
        content.title = "Plan: \(plan.name)"
        content.body = String(result.prefix(200))
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "plan-\(plan.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Schedule next BGTask for the earliest due plan.
    func scheduleNextCheck() {
        let nextDuePlan = planStore.plans
            .filter { $0.enabled }
            .compactMap { plan -> (Plan, Date)? in
                guard let next = plan.schedule.nextFireDate() else { return nil }
                return (plan, next)
            }
            .min(by: { $0.1 < $1.1 })
        
        guard let (_, nextDate) = nextDuePlan else { return }
        
        let request = BGProcessingTaskRequest(identifier: "com.neox.plan.process")
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = nextDate
        
        try? BGTaskScheduler.shared.submit(request)
    }
}
```

### 5.3 Manual Execution (Foreground)

```swift
// User taps "Run Now" — executes in foreground, no BGTask needed
func runPlanManually(_ plan: Plan) async {
    await PlanExecutor.shared.executePlan(plan)
}
```

---

## 6. UI Design

### 6.1 Plan List (in Settings or dedicated tab)

```
┌─────────────────────────────────┐
│ Plans                     [+]   │
│                                 │
│ ┌─────────────────────────────┐ │
│ │ 📋 Morning GitHub Digest   │ │
│ │ Every weekday at 8am       │ │
│ │ Last: ✅ 2h ago            │ │
│ │ [gpt-4.1-mini]            │ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─────────────────────────────┐ │
│ │ 📱 Weekly Dev Update Post   │ │
│ │ Fridays at 5pm  ⏸ disabled │ │
│ │ Last: ✅ 5d ago            │ │
│ │ [gpt-4.1]                 │ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─────────────────────────────┐ │
│ │ 🔍 Monitor PR #42          │ │
│ │ Every 30 min                │ │
│ │ Last: ⏳ running            │ │
│ │ [gpt-4.1-nano]            │ │
│ └─────────────────────────────┘ │
└─────────────────────────────────┘
```

### 6.2 Plan Editor

```
┌─────────────────────────────────┐
│ New Plan                        │
│                                 │
│ Name: [Morning GitHub Digest  ] │
│                                 │
│ Prompt:                         │
│ ┌─────────────────────────────┐ │
│ │ Check my GitHub notifica-   │ │
│ │ tions and summarize new     │ │
│ │ issues, PRs, and reviews.   │ │
│ └─────────────────────────────┘ │
│                                 │
│ Schedule:                       │
│ ○ Manual  ● Recurring  ○ Once  │
│                                 │
│ Every: [weekday] at [8:00 AM]   │
│                                 │
│ Model: [gpt-4.1-mini      ▾]   │
│                                 │
│ ☑ Requires approval for actions │
│ Token budget: [50000]           │
│                                 │
│        [Cancel]  [Save Plan]    │
└─────────────────────────────────┘
```

### 6.3 Execution Detail

```
┌─────────────────────────────────┐
│ ← Morning GitHub Digest         │
│                                 │
│ Today 8:00 AM → ✅ Completed    │
│ Duration: 1m 23s                │
│ Tokens: 2,340 + 890 = $0.009   │
│                                 │
│ ┌─────────────────────────────┐ │
│ │ ## GitHub Digest             │ │
│ │                             │ │
│ │ **New Issues (3)**          │ │
│ │ - #123: Fix login bug       │ │
│ │ - #124: Add dark mode       │ │
│ │ - #125: Performance issue   │ │
│ │                             │ │
│ │ **PRs Ready for Review (1)**│ │
│ │ - #42: Auth refactor        │ │
│ └─────────────────────────────┘ │
│                                 │
│ [▶ Run Now]  [Edit]  [History] │
└─────────────────────────────────┘
```

---

## 7. Plan Results → Chat Integration

All plan executions log to a **single "Plans" chat thread** — a dedicated conversation that serves as a central log. This keeps chat history clean while giving visibility into plan activity.

### 7.1 Single Plans Thread

- On first plan execution, create a conversation with `title: "Plans"` and `source: .plans`
- Every subsequent plan result is **appended** as a pair of messages:
  - System/user message: `"[Plan: Morning Digest] ran at 8:02am"`
  - Assistant message: the plan's result markdown
- The thread grows over time as a chronological log of all plan activity

### 7.2 Chat Thread Creation

```swift
// In PlanExecutor, after collecting the result:
func logToPlansThread(plan: Plan, execution: PlanExecution) {
    let chatStore = ChatStore.shared
    
    // Get or create the single Plans thread
    let thread = chatStore.getOrCreatePlansThread()
    
    // Append plan result as messages
    let header = "**[\(plan.name)]** — \(execution.startedAt.formatted(.dateTime.month().day().hour().minute()))"
    let status = execution.status == .completed ? "✅" : "❌"
    let costStr = execution.cost.map { CostCalculator.formatCost($0) } ?? ""
    
    thread.appendMessage(ChatMessage(
        role: .user,
        content: "\(status) \(header) \(costStr)"
    ))
    thread.appendMessage(ChatMessage(
        role: .assistant,
        content: execution.result ?? execution.error ?? "No output"
    ))
    
    chatStore.save()
}

// ChatStore extension:
func getOrCreatePlansThread() -> Conversation {
    if let existing = conversations.first(where: { $0.source == .plans }) {
        return existing
    }
    let thread = Conversation(
        id: "plans-log",
        title: "Plans",
        source: .plans,
        messages: [],
        createdAt: Date()
    )
    addConversation(thread)
    return thread
}
```

### 7.3 Foreground Behavior

If the app is in foreground when a plan fires:
- Result appended to the Plans thread
- A subtle banner: "Plan 'Morning Digest' completed · [View](tap to open Plans thread)"

### 7.4 Example Plans Thread

```
┌─────────────────────────────────┐
│ Plans                           │
│                                 │
│ ✅ [Morning Digest] Jul 18 8:02 │
│ ─────────────────────────────── │
│ ## GitHub Digest                │
│ - 3 new issues in neox-app     │
│ - 1 PR ready for review        │
│                                 │
│ ✅ [Monitor PR #42] Jul 18 8:30 │
│ ─────────────────────────────── │
│ PR #42 still awaiting review.   │
│ No new comments since last check│
│                                 │
│ ❌ [Weekly Post] Jul 18 9:00    │
│ ─────────────────────────────── │
│ Error: Insufficient balance     │
└─────────────────────────────────┘
```

---

## 8. Calendar Integration (EventKit)

Plans should integrate with the iOS Calendar to enable context-aware scheduling and event-driven plans.

### 8.1 Uses

| Feature | Description |
|---------|-------------|
| **Calendar-triggered plans** | "Before my 3pm meeting, prepare a summary of the project" — plan fires relative to calendar events |
| **Calendar context in prompts** | Plans can include `{{calendar_today}}` to inject today's schedule into the prompt |
| **Result → Calendar event** | Plan results can create calendar events (e.g., "Schedule follow-up for next Tuesday") |
| **Smart scheduling** | Avoid running plans during meetings; prefer gaps between events |

### 8.2 EventKit Access

```swift
import EventKit

class CalendarProvider {
    private let store = EKEventStore()
    
    /// Request calendar access (read-only for context; read-write for creating events).
    func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await store.requestAccess(to: .event)
        }
    }
    
    /// Get today's events for prompt injection.
    func todayEvents() -> [EKEvent] {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
    }
    
    /// Find next event matching criteria (for calendar-triggered plans).
    func nextEvent(matching title: String, after: Date = Date()) -> EKEvent? {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: after)!
        let predicate = store.predicateForEvents(withStart: after, end: end, calendars: nil)
        return store.events(matching: predicate)
            .first { $0.title?.localizedCaseInsensitiveContains(title) == true }
    }
    
    /// Create a calendar event from plan result.
    func createEvent(title: String, startDate: Date, duration: TimeInterval = 3600, notes: String? = nil) throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(duration)
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }
}
```

### 8.3 Calendar Schedule Type

Extend `PlanSchedule` to support calendar-relative timing:

```swift
enum PlanSchedule: Codable {
    case manual
    case once(at: Date)
    case interval(seconds: Int)
    case cron(expression: String, timezone: String)
    case beforeCalendarEvent(matching: String, minutesBefore: Int)  // NEW
    case afterCalendarEvent(matching: String, minutesAfter: Int)    // NEW
}
```

### 8.4 Prompt Template Variables

Plans can reference calendar context via template variables:

| Variable | Expansion |
|----------|-----------|
| `{{calendar_today}}` | "9:00 AM - Standup\n10:00 AM - Design Review\n..." |
| `{{calendar_next}}` | "Next: Design Review at 10:00 AM (in 45 min)" |
| `{{calendar_event_title}}` | Title of the triggering calendar event |
| `{{calendar_event_notes}}` | Notes from the triggering calendar event |

Example plan prompt:
```
Here is my schedule today:
{{calendar_today}}

Please prepare a brief summary of what I should focus on before my first meeting.
```

### 8.5 Implementation Phase

Calendar integration is Phase 3+ (after basic plans and BGTask scheduling work). It requires:
1. `NSCalendarsUsageDescription` in Info.plist
2. Permission request flow in PlanManagerView
3. CalendarProvider utility class
4. Template variable expansion in PlanExecutor

---

## 9. Approval Flow

For plans with `requiresApproval: true`:

1. During execution, if the agent triggers an action tool (e.g., posting, sending), the existing `ask_user` mechanism fires
2. In foreground: normal ask_user sheet appears
3. In background: post local notification with action buttons (Approve / Reject)
4. Notification response wired back to `ask_user` reply

```swift
// In PlanExecutor.executePlan(), handle ask_user:
await session.on(.externalToolRequested) { event in
    if plan.requiresApproval {
        // Post notification with actionable buttons
        let approved = await self.requestApproval(plan: plan, action: event)
        if !approved {
            // Cancel the session
            try? await session.disconnect()
        }
    }
}
```

---

## 10. Integration with Payment System

Plans consume tokens from the same client-authoritative balance (see [design-payment-usage.md](design-payment-usage.md)):

- Each plan session emits `assistant.usage` events → UsageTracker records them
- Plan `maxTokenBudget` provides per-execution safety limit
- If balance reaches $0, plan execution aborts with "insufficient balance" error
- Plan execution detail shows cost breakdown

---

## 11. Limitations & Mitigations

| Limitation | Impact | Mitigation |
|-----------|--------|------------|
| iOS may delay BGTask by minutes/hours | Plan won't fire at exact time | UI shows "approximate" timing; manual trigger always available |
| BGProcessingTask capped at ~minutes | Long agent sessions may be killed | Set timeout, save partial results |
| App must be installed (not offloaded) | If iOS offloads app, tasks stop | Keep app active |
| No execution when phone is off/dead | Plans simply don't run | Accept this trade-off; user chose simplicity |
| Only one BGProcessingTask at a time | Can't run multiple plans simultaneously | Queue plans, execute sequentially |

---

## 12. Implementation Phases

### Phase 1: Manual Plans + Persistence
1. `Plan` and `PlanExecution` data models
2. `PlanStore` — JSON file persistence in Documents
3. `PlanManagerView` — list + create/edit
4. Manual "Run Now" — foreground execution via CopilotClient
5. **Single "Plans" chat thread** — log all plan results to one conversation
6. Add "Plans" section in Settings

### Phase 2: Background Scheduling
7. BGTaskScheduler registration in AppDelegate
8. `PlanExecutor` — BGProcessingTask handler
9. Schedule picker UI (time, weekday, interval, cron)
10. Execution history + detail views
11. Local notifications on completion

### Phase 3: Approval + Notifications
11. Ask_user handling during background execution
12. Actionable notification buttons (Approve/Reject)
13. Token budget enforcement per execution
14. Integration with UsageTracker for cost display

### Phase 4: Advanced
15. Siri Shortcuts ("Run Morning Digest")
16. "Plan from chat" — extract plan from conversation
17. Plan templates (pre-built common plans)
18. Live Activity for currently-running plan

---

## 13. Open Questions

1. **Cron parsing**: Use a Swift cron parsing library (e.g., `SwiftCron`), or simpler "every weekday at 8am" presets?
2. **Execution timeout**: What's reasonable? 2 minutes? 5 minutes?
3. **History retention**: Keep last N executions per plan? Or prune by age?
4. **Plan from chat**: "Save this conversation as a plan" — how to extract prompt + schedule from natural language?
