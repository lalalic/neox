# Remote Project Dev with Copilot Coding Agent

> **Prerequisite**: [Coding Agent Architecture — Infinite-Loop Project Delivery](coding-agent-project-delivery-design-v2.md) covers the foundational relay, session lifecycle, and two-tier agent system this design builds on.

## 1. Problem

A Neox user wants to build an iOS app from their phone. They describe the idea, the agent decomposes it, dispatches work to GitHub's Copilot coding agent, and delivers a TestFlight build they can install and test. Today this requires a developer to manually set up repos, write code, configure CI/CD, and manage TestFlight. The goal: **user describes an app → agent builds and ships it**.

---

## 2. What Already Exists

| Component | Status | Description |
|-----------|--------|-------------|
| Relay server | ✅ Implemented | Multi-workspace, session pooling, agent loop, hold state, snapshots |
| Agent loop | ✅ Implemented | `send_response` + `ask_user` keep agent running indefinitely |
| Two-tier architecture | ✅ Designed | Local orchestrator (Tier 1) dispatches to cloud workers (Tier 2) |
| TestFlight workflow | ✅ Exists | `neox/.github/workflows/testflight.yml` — archive, sign, upload |
| Auto-merge workflow | ✅ Exists | `copilot-ios/.github/workflows/auto-merge.yml` — CI check, scope check, squash merge |
| CI workflow | ✅ Exists | `copilot-ios/.github/workflows/ci.yml` — build + test on PR |
| Skill discovery | ✅ Implemented | `.github/skills/*/SKILL.md` scanned and injected into system prompt |
| Issue spec template | ✅ Designed | In `coding-agent-project-delivery-design-v2.md` |

---

## 3. Architecture

### 3.1 Overview

```
User (Neox app)
    │
    │  "I want a weather app with hourly forecasts"
    ▼
Agent (relay session, Tier 1 — on-device)
    │
    ├── 1. create_task("weather app with hourly forecasts")
    │      → creates repo: neox-apps/weather-abc123 (from template)
    │      → creates issue #1: "SwiftUI scaffold with tab navigation"
    │      → assigns custom coding agent
    │
    │   ┌──────── Custom Coding Agent (GitHub cloud VM) ─────────┐
    │   │                                                         │
    │   │  MCP connections:                                       │
    │   │    • relay MCP (send_response, ask_user)                │
    │   │    • github-api MCP (workflow status polling)            │
    │   │                                                         │
    │   │  1. Code feature                                        │
    │   │     send_response("Working on tab nav...")  ──────► User sees progress
    │   │     ask_user("Grid or list for Home?")      ◄─────► User answers "grid"
    │   │                                                         │
    │   │  2. Push code → create PR                               │
    │   │     send_response("PR #1 created, CI running...")       │
    │   │                                                         │
    │   │  3. Wait for CI (build + test on self-hosted runner)    │
    │   │     Auto-merge when CI passes                           │
    │   │                                                         │
    │   │  4. Wait for deploy workflow                             │
    │   │     (self-hosted runner: archive → sign → TestFlight)   │
    │   │                                                         │
    │   │  5. send_response("Build #42 on TestFlight!") ──────► User notified
    │   │     Session ends                                        │
    │   └─────────────────────────────────────────────────────────┘
    │
    └── User installs from TestFlight → tests → feedback
        → agent calls create_task(feedback) → iterate
```

**Key insight**: The custom coding agent in the cloud VM stays alive through the entire cycle — from coding to TestFlight upload. It communicates with the user via relay MCP tools throughout, and monitors the build/deploy via GitHub API. No webhooks needed.

### 3.2 Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Coding agent | Custom agent on GitHub cloud VM | Full control over behavior, MCP-enabled |
| Communication | Relay MCP bridge (`send_response`, `ask_user`) | Same pattern as local agent, bidirectional |
| Build monitoring | Agent polls GitHub API for workflow status | Agent waits for build/deploy, reports completion |
| Repo ownership | Platform-managed org (`neox-apps`) | Users don't need GitHub accounts |
| CI/CD runner | Self-hosted macOS | Cheapest, full control, one machine serves all users |
| App scope | General iOS apps | Template provides SwiftUI scaffold; coding agent implements features |
| Delivery | TestFlight | User installs and tests on their actual device |
| User identity | Neox appId → repo mapping | Each user-project gets unique repo in org |

---

## 4. Components

### 4.1 Platform GitHub Org

**Org**: `neox-apps` (or similar)

**Repo naming**: `{project-slug}-{short-id}` (e.g., `weather-abc123`)

**Repo ↔ User mapping**: Stored in relay's workspace config or a `projects.json`:
```json
{
  "abc123": {
    "repo": "neox-apps/weather-abc123",
    "userId": "user-456",
    "appId": "com.neox-apps.weather-abc123",
    "name": "Weather App",
    "created": "2026-04-02T10:00:00Z",
    "status": "active"
  }
}
```

**Org-level settings**:
- Copilot coding agent enabled for the org
- Self-hosted macOS runner registered
- Org-level secrets: Apple signing cert, provisioning profile, ASC API key
- Branch protection on `main`: require CI pass, allow auto-merge

### 4.2 Template Repo

A template repository (`neox-apps/ios-app-template`) that every new project is created from. Contains:

```
ios-app-template/
├── .github/
│   ├── copilot-instructions.md     # Agent behavior rules for this project
│   ├── workflows/
│   │   ├── ci.yml                  # Build + test on PR
│   │   ├── auto-review.yml         # Scope check + auto-merge for copilot PRs
│   │   └── deploy.yml              # Build + sign + TestFlight on merge to main
│   └── copilot-setup-steps.yml     # VM setup for coding agent (Xcode, deps)
├── Sources/
│   └── App/
│       ├── MyApp.swift             # @main entry point
│       ├── ContentView.swift       # Root view
│       └── Info.plist
├── Tests/
│   └── AppTests/
│       └── AppTests.swift
├── Package.swift                   # SPM manifest
├── project.yml                     # XcodeGen spec (scheme, targets, settings)
├── ExportOptions.plist             # IPA export config
└── README.md
```

**Template variables** (replaced on repo creation):
- `{{APP_NAME}}` → "Weather App"
- `{{BUNDLE_ID}}` → "com.neox-apps.weather-abc123"
- `{{TEAM_ID}}` → "JABNLDLN8G"

### 4.3 GitHub Actions Workflows

#### ci.yml (runs on every PR)

```yaml
name: CI
on:
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: self-hosted  # macOS runner
    steps:
      - uses: actions/checkout@v4
      - name: Generate Xcode project
        run: xcodegen generate
      - name: Build
        run: |
          xcodebuild build \
            -project App.xcodeproj \
            -scheme App \
            -destination 'platform=iOS Simulator,name=iPhone 16'
      - name: Test
        run: |
          xcodebuild test \
            -project App.xcodeproj \
            -scheme App \
            -destination 'platform=iOS Simulator,name=iPhone 16'
```

#### auto-review.yml (auto-merge copilot PRs)

Reuse existing pattern from `copilot-ios/.github/workflows/auto-merge.yml`:
1. Wait for CI to complete
2. Scope check: no sensitive files, <500 line changes
3. Squash merge

#### deploy.yml (build + TestFlight on merge to main)

Reuse existing pattern from `neox/.github/workflows/testflight.yml`:
1. Install Apple certificate + provisioning profile (from org secrets)
2. XcodeGen → archive → export IPA
3. Upload to TestFlight via `xcrun altool`

No webhook needed — the custom coding agent monitors this workflow's completion via GitHub API and reports to the user directly via MCP.

### 4.4 Self-Hosted macOS Runner

**Hardware**: Mac Mini / Mac Studio (or existing development Mac)

**Setup**:
1. Install GitHub Actions runner (org-level, shared across all repos)
2. Install Xcode, XcodeGen, CocoaPods (if needed)
3. Label: `self-hosted`, `macOS`, `xcode16`
4. Service mode: `./svc.sh install && ./svc.sh start`

**Scaling**: One runner with concurrency 1 is fine for MVP. Queue builds serially. Can add runners later.

**Security**: Runner is org-scoped, only accessible to `neox-apps` repos. Secrets stored at org level.

### 4.5 Agent Tools

Two distinct tool layers serve different purposes:

#### On-Device Tools (called by the phone agent)

| Tool | Description | Scope |
|------|-------------|-------|
| `create_project` | Create a local project on the device (any kind — not GitHub-specific) | On-device, already exists |
| `create_task` | Full pipeline: create repo (if needed) → create issue with spec → assign custom coding agent | Relay-side handler, calls GitHub API |

`create_task` is the single entry point for dispatching work to the cloud. It handles:
1. Check if project has a repo; if not, create from template + replace variables
2. Create GitHub issue with spec (goal, context, constraints, validation)
3. Assign to the custom coding agent
4. Return: issue URL, repo URL

No `get_project_status` or `get_build_status` tools needed — the coding agent reports status back through the MCP bridge.

#### Relay MCP Server (called by the custom coding agent in the cloud VM)

The relay exposes an MCP server endpoint configured in each project repo. The custom coding agent calls these tools throughout its lifecycle — from coding through build/deploy:

| Tool | Description |
|------|-------------|
| `send_response` | Report progress or completion to the user on their phone |
| `ask_user` | Ask the user a question and wait for their answer |

**Configuration**: In each repo's `.github/copilot-mcp.json` (or repo settings → MCP servers):
```json
{
  "mcpServers": {
    "neox-relay": {
      "url": "https://relay.ai.qili2.com/mcp",
      "auth": { "type": "bearer", "token": "{{PROJECT_TOKEN}}" }
    }
  }
}
```

#### Custom Coding Agent Definition

Defined in each repo's `.github/agents/builder.agent.md`:

```markdown
---
name: builder
model: gpt-4.1
description: "Codes features, creates PRs, waits for build/deploy, reports to user"
---

You are a coding agent that implements features and delivers them to TestFlight.

## Workflow
1. Read the issue spec carefully
2. Implement the feature (code, tests)
3. Call send_response to report progress to the user
4. If you have questions, call ask_user and wait for the answer
5. Push code and create a PR
6. Wait for CI to pass (poll workflow status)
7. After CI passes, auto-merge the PR
8. Wait for the deploy workflow to complete (poll workflow status)
9. Call send_response("Build #{number} uploaded to TestFlight!")
10. Session ends
```

**The agent stays alive through the full cycle**: coding → PR → CI → merge → deploy → TestFlight. It reports every step to the user via `send_response` and asks questions via `ask_user`.

**Build status polling**: The agent monitors GitHub Actions workflow runs via the GitHub API (available in the cloud VM environment) to know when CI passes and when deploy completes.

### 4.6 Apple Developer Account & Code Signing

**Single Apple Developer account** (yours, team ID `JABNLDLN8G`) hosts all user apps.

**Per-app requirements**:
- Unique Bundle ID: `com.neox-apps.{project-slug}`
- App ID registered in Apple Developer portal
- Provisioning profile (wildcard `com.neox-apps.*` simplifies this)

**Wildcard approach** (recommended for MVP):
- One wildcard App ID: `com.neox-apps.*`
- One wildcard provisioning profile
- All apps share the same signing identity
- Limitation: no push notifications, no app-specific entitlements (fine for MVP)

**Scaling**: When a user graduates to App Store (not just TestFlight), create a dedicated App ID and profile.

### 4.7 Communication Bridge (Relay MCP → Phone)

The relay MCP server is the central communication hub. The custom coding agent in the cloud VM calls MCP tools on the relay throughout its entire lifecycle, which routes messages to the user's phone session.

**How status flows:**
```
Coding agent picks up Issue #1
  → calls send_response("Starting work on tab navigation...")
  → relay routes to user's active Neox session
  → user sees progress in chat

Coding agent has a question
  → calls ask_user("3 tabs planned. Should Home show a grid or list?")
  → relay holds the coding agent's MCP call
  → user sees the question on their phone
  → user answers "grid"
  → relay returns answer to coding agent
  → coding agent continues

Coding agent pushes code, creates PR
  → calls send_response("PR #1 created. CI running...")
  → monitors CI workflow via GitHub API

CI passes → auto-merge → deploy workflow starts
  → calls send_response("PR merged. Building for TestFlight...")
  → monitors deploy workflow via GitHub API

Deploy completes
  → calls send_response("Build #42 uploaded to TestFlight! Install to test.")
  → session ends
```

**No webhooks needed**: The agent stays alive through the full cycle and reports directly via MCP. This is simpler and more reliable than webhook-based notification.

**Session routing**: The relay maps `projectId → userId → active session`. If the user is disconnected, messages are queued and delivered on next connect (same hold-state mechanism as the local agent).

---

## 5. User Flow (End-to-End)

### 5.1 Project Creation

```
User: "I want to build a recipe sharing app where people can post photos of their meals"

Agent:
  1. Acknowledges idea, asks clarifying questions:
     - "What features for MVP? Photo posting, feed, user profiles?"
     - "Any specific design preference?"
  2. Decomposes into plan:
     - Phase 1: App scaffold + photo capture
     - Phase 2: Recipe data model + local storage
     - Phase 3: Feed UI + photo grid
  3. Creates project:
     - POST github.com/orgs/neox-apps/repos (from template)
     - Replaces template variables
     - Enables Copilot coding agent
  4. Reports: "Created your project! Starting development..."
```

### 5.2 Task Dispatch

```
Agent creates issues:

Issue #1: "Setup SwiftUI app with tab navigation (Home, Camera, Profile)"
  → Spec: TabView with 3 tabs, placeholder views, SF Symbols icons
  → Assigned to @copilot → coding agent creates PR #1

Issue #2: "Photo capture with CameraKit integration"
  → Spec: Camera view, photo preview, save to Photos
  → Assigned to @copilot → coding agent creates PR #2

Issue #3: "Recipe model with Core Data persistence"
  → Spec: Recipe entity (title, photo, ingredients, steps), CRUD operations
  → Assigned to @copilot → coding agent creates PR #3
```

### 5.3 Build & Deploy

```
PR #1 merged → deploy.yml runs → TestFlight build #1
  → Webhook → relay → agent → "Build #1 ready! Install from TestFlight."

User installs, tests.

User: "The tab icons are too small and the Home tab should show a grid"
  → Agent creates Issue #4 from feedback
  → Coding agent creates PR → merge → build #2 → TestFlight
```

### 5.4 Iteration Loop

```
User tests → feedback → agent creates issues → coding agent builds → TestFlight → repeat
```

---

## 6. Data Model

### 6.1 Project Registry

Stored as `projects.json` on the relay server (file-based, no database for MVP):

```json
{
  "projects": {
    "recipe-7f3a2b": {
      "repo": "neox-apps/recipe-7f3a2b",
      "userId": "user-456",
      "appId": "com.neox-apps.recipe-7f3a2b",
      "displayName": "Recipe Sharing App",
      "bundleId": "com.neox-apps.recipe-7f3a2b",
      "created": "2026-04-02T10:00:00Z",
      "status": "active",
      "testflightUrl": null,
      "lastBuild": null
    }
  }
}
```

### 6.2 Issue Spec Template

Every issue dispatched to the coding agent follows this format:

```markdown
## Goal
[One sentence: what should change]

## Context
[Files/modules involved, current behavior, dependencies]

## Spec
- [ ] [Specific requirement 1]
- [ ] [Specific requirement 2]

## Constraints
- Must work on iOS 17+
- SwiftUI only (no UIKit)
- No third-party dependencies unless specified

## Validation
- [ ] `xcodebuild build` succeeds
- [ ] `xcodebuild test` passes
- [ ] [Behavioral check]

## Out of Scope
[What NOT to touch]
```

---

## 7. Security & Isolation

| Concern | Mitigation |
|---------|------------|
| User code isolation | Each project is a separate repo; coding agent runs in isolated VM |
| Signing credentials | Org-level secrets, never in repo. Wildcard profile limits blast radius |
| Repo access | Bot account manages all repos; users never get direct GitHub access |
| Runner security | Org-scoped runner, only accepts jobs from `neox-apps` repos |
| API keys (weather, etc.) | User provides via chat → agent stores in repo secrets (never in code) |
| Cost control | Rate limit: one project per user, N issues per day |

---

## 8. Limitations & Future Work

### MVP Limitations
- **No App Store submission** — TestFlight only. App Store requires review, screenshots, metadata.
- **No push notifications** — wildcard provisioning profile doesn't support APNs.
- **No custom domains / backend** — MVP apps are client-only. Backend requires separate infrastructure.
- **Serial builds** — one runner, one build at a time. Users queue behind each other.
- **No direct GitHub access** — users interact only through Neox chat.

### Future Phases

| Phase | Feature | Description |
|-------|---------|-------------|
| 2 | Backend support | Add a simple backend template (Vapor/Node.js + database) |
| 2 | User GitHub linking | OAuth flow to let users fork their repo to their own account |
| 3 | App Store submission | Automated screenshot generation, metadata, App Store review submission |
| 3 | Multi-platform | Android support via KMM or separate template |
| 3 | Custom domains | Each app gets a web landing page |
| 4 | Marketplace | Users can publish and share apps within Neox ecosystem |

---

## 9. Implementation Plan (High-Level)

### Phase 1: Foundation (Week 1-2)

1. **GitHub org setup** — Create `neox-apps` org, enable Copilot coding agent
2. **Template repo** — iOS app template with workflows (ci, auto-review, deploy)
3. **Self-hosted runner** — Register macOS runner, verify builds work
4. **Wildcard signing** — Create wildcard App ID + provisioning profile

### Phase 2: Agent Tools (Week 2-3)

5. **GitHub MCP server** — `create_project`, `create_task`, `get_project_status`, `send_feedback`
6. **Project registry** — `projects.json` on relay, CRUD operations
7. **Agent skill** — `project-dev/SKILL.md` with flow instructions for the agent

### Phase 3: Integration (Week 3-4)

8. **Webhook endpoint** — Relay receives deploy notifications, routes to user session
9. **TestFlight flow** — End-to-end: create project → issues → PRs → build → TestFlight
10. **User testing loop** — Feedback → new issues → iterate

### Phase 4: Polish (Week 4+)

11. **Error handling** — Build failures, agent stuck, signing issues
12. **Rate limiting** — Per-user project/issue limits
13. **Dashboard** — Project status view in Neox app (issues, builds, TestFlight links)

---

## 10. Open Questions

1. **Copilot coding agent limits** — How many concurrent sessions per org? Rate limits?
2. **TestFlight external testing** — Do external testers need Apple IDs? How to distribute invite links automatically?
3. **Template complexity** — Should the template include common libraries (Alamofire, Kingfisher) or stay minimal?
4. **Cost model** — How to bill users? Per-build? Per-project? Subscription?
5. **Coding agent quality** — For complex UI, will the coding agent produce good-enough SwiftUI? May need human review for UX-critical PRs.
