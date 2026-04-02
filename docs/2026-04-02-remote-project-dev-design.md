# Remote Project Dev with Copilot Coding Agent

> **Prerequisite**: [Coding Agent Architecture — Infinite-Loop Project Delivery](coding-agent-project-delivery-design-v2.md) covers the foundational relay, session lifecycle, and two-tier agent system this design builds on.

## 1. Problem

A Neox user wants to build an app from their phone. They describe the idea, the agent decomposes it, dispatches work to a custom coding agent on GitHub, and delivers a TestFlight build they can install and test. The goal: **user describes an app → agent builds and ships it**.

---

## 2. What Already Exists

| Component | Status | Description |
|-----------|--------|-------------|
| Relay server | ✅ Implemented | Multi-workspace, session pooling, agent loop, hold state, snapshots |
| Agent loop | ✅ Implemented | `send_response` + `ask_user` keep agent running indefinitely |
| Two-tier architecture | ✅ Designed | Local orchestrator (Tier 1) dispatches to cloud workers (Tier 2) |
| Auto-merge workflow | ✅ Exists | `copilot-ios/.github/workflows/auto-merge.yml` — CI check, scope check, squash merge |
| Skill discovery | ✅ Implemented | `.github/skills/*/SKILL.md` scanned and injected into system prompt |
| Issue spec template | ✅ Designed | In `coding-agent-project-delivery-design-v2.md` |
| EAS CLI | ✅ Installed | Logged in as `lalalic`, Apple Developer membership active |

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
    │      → creates repo: neos/weather-abc123 (from template)
    │      → creates issue #1: "App scaffold with tab navigation"
    │      → assigns custom coding agent
    │
    │   ┌──────── Custom Coding Agent (GitHub cloud VM) ─────────┐
    │   │                                                         │
    │   │  MCP connections:                                       │
    │   │    • relay MCP (send_response, ask_user)                │
    │   │    • github-api MCP (workflow status polling)            │
    │   │                                                         │
    │   │  1. Code feature (Expo / React Native)                  │
    │   │     send_response("Working on tab nav...")  ──────► User sees progress
    │   │     ask_user("Grid or list for Home?")      ◄─────► User answers "grid"
    │   │                                                         │
    │   │  2. Push code → create PR                               │
    │   │     send_response("PR #1 created, CI running...")       │
    │   │                                                         │
    │   │  3. Wait for CI (lint + type check + test)              │
    │   │     Auto-merge when CI passes                           │
    │   │                                                         │
    │   │  4. Trigger EAS Build → wait for completion             │
    │   │     (EAS cloud macOS builder: Expo prebuild → Xcode     │
    │   │      archive → sign → TestFlight upload)                │
    │   │                                                         │
    │   │  5. send_response("Build #42 on TestFlight!") ──────► User notified
    │   │     Session ends                                        │
    │   └─────────────────────────────────────────────────────────┘
    │
    └── User installs from TestFlight → tests → feedback
        → agent calls create_task(feedback) → iterate
```

**Key insight**: The custom coding agent stays alive through the entire cycle — from coding to TestFlight. It communicates with the user via relay MCP, and triggers/monitors EAS Build via CLI. No self-hosted runner or manual signing needed.

### 3.2 Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| App framework | **Expo (React Native)** | Cross-platform, EAS handles builds/signing, JS/TS is widely known |
| Build service | **EAS Build** | Cloud macOS builders, automatic code signing, TestFlight upload |
| Coding agent | Custom agent on GitHub cloud VM | Full control, MCP-enabled, stays alive through build |
| Communication | Relay MCP bridge (`send_response`, `ask_user`) | Same pattern as local agent, bidirectional |
| Repo ownership | Platform-managed org (`neos`) | Users don't need GitHub accounts |
| Delivery | TestFlight (via EAS Submit) | User installs and tests on their actual device |

### 3.3 Why Expo over Native iOS

| Concern | Native iOS | Expo |
|---------|-----------|------|
| Build infrastructure | Self-hosted macOS runner ($400+ hardware) | EAS Build (cloud, free tier: 30 builds/month) |
| Code signing | Manual cert + profile management | `eas credentials` manages everything |
| TestFlight upload | `xcrun altool` with API key | `eas submit` handles it |
| Language | Swift (fewer devs, agent less fluent) | TypeScript (universal, agent excels) |
| Template complexity | XcodeGen + SPM + Info.plist | `npx create-expo-app` |
| Cross-platform | iOS only | iOS + Android + Web |
| Hot reload | None in prod | Expo Updates (OTA updates without rebuild) |

---

## 4. Components

### 4.1 Platform GitHub Org

**Org**: `neos`  
**GitHub account**: `lalalic1`

**Repo naming**: `{project-slug}-{short-id}` (e.g., `weather-abc123`)

**Repo ↔ User mapping**: Stored as `projects.json` on the relay:
```json
{
  "abc123": {
    "repo": "neos/weather-abc123",
    "userId": "user-456",
    "displayName": "Weather App",
    "easProjectId": "xxx-xxx-xxx",
    "created": "2026-04-02T10:00:00Z",
    "status": "active"
  }
}
```

**Org-level settings**:
- Custom coding agent enabled
- Org-level secrets: `EXPO_TOKEN` (EAS authentication)
- Branch protection on `main`: require CI pass, allow auto-merge

### 4.2 Template Repo

A template repository (`neos/expo-app-template`) that every new project is created from:

```
expo-app-template/
├── .github/
│   ├── copilot-instructions.md      # Agent behavior rules
│   ├── copilot-mcp.json             # MCP servers (relay)
│   ├── agents/
│   │   └── builder.agent.md         # Custom coding agent definition
│   ├── workflows/
│   │   ├── ci.yml                   # Lint + type check + test on PR
│   │   └── auto-review.yml          # Scope check + auto-merge for agent PRs
│   └── copilot-setup-steps.yml      # VM setup (Node.js, EAS CLI)
├── app/
│   ├── _layout.tsx                  # Root layout (Expo Router)
│   ├── index.tsx                    # Home screen
│   └── +not-found.tsx
├── app.json                         # Expo config
├── eas.json                         # EAS Build profiles
├── package.json
├── tsconfig.json
└── README.md
```

**Template variables** (replaced on repo creation):
- `{{APP_NAME}}` → "Weather App"
- `{{APP_SLUG}}` → "weather-abc123"
- `{{BUNDLE_ID}}` → "com.neos.weather-abc123"

### 4.3 EAS Configuration

#### eas.json

```json
{
  "cli": { "version": ">= 18.0.0" },
  "build": {
    "preview": {
      "distribution": "internal",
      "ios": { "simulator": true }
    },
    "production": {
      "ios": {
        "autoIncrement": true
      }
    }
  },
  "submit": {
    "production": {
      "ios": {
        "appleId": "lalalic@139.com",
        "ascAppId": "{{ASC_APP_ID}}",
        "appleTeamId": "JABNLDLN8G"
      }
    }
  }
}
```

#### app.json (key fields)

```json
{
  "expo": {
    "name": "{{APP_NAME}}",
    "slug": "{{APP_SLUG}}",
    "version": "1.0.0",
    "ios": {
      "bundleIdentifier": "{{BUNDLE_ID}}",
      "supportsTablet": true
    }
  }
}
```

### 4.4 GitHub Actions Workflows

#### ci.yml (runs on every PR)

```yaml
name: CI
on:
  pull_request:
    branches: [main]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - run: npx tsc --noEmit
      - run: npx eslint .
      - run: npm test
```

No macOS runner needed — CI just checks TypeScript types, lint, and tests.

#### auto-review.yml

Same pattern as `copilot-ios/.github/workflows/auto-merge.yml`:
1. Wait for CI (ubuntu, fast)
2. Scope check: no sensitive files, <500 line changes
3. Squash merge

### 4.5 Agent Tools

#### On-Device Tools (called by the phone agent via relay)

| Tool | Description |
|------|-------------|
| `create_project` | Create a local project on device (any kind, not GitHub-specific) |
| `create_task` | Full pipeline: create repo (if needed) → create issue with spec → assign coding agent |

`create_task` handles:
1. Check if project has a repo; if not, create from template + replace variables + `eas init`
2. Create GitHub issue with spec
3. Assign to the custom coding agent
4. Return: issue URL, repo URL

#### Relay MCP Server (called by the custom coding agent in the cloud VM)

| Tool | Description |
|------|-------------|
| `send_response` | Report progress or completion to user's phone |
| `ask_user` | Ask user a question, wait for answer |

**MCP config** (`.github/copilot-mcp.json`):
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

`.github/agents/builder.agent.md`:

```markdown
---
name: builder
model: gpt-4.1
description: "Codes features, creates PRs, builds with EAS, reports to user"
---

You are a coding agent that implements features and delivers them to TestFlight.

## Workflow
1. Read the issue spec carefully
2. Implement the feature (TypeScript, React Native, Expo)
3. Call send_response to report progress to the user
4. If you have questions, call ask_user and wait for the answer
5. Push code and create a PR
6. Wait for CI to pass (type check + lint + test)
7. After CI passes, merge the PR
8. Run: `npx eas-cli build --platform ios --profile production --non-interactive`
9. Wait for EAS Build to complete (poll `eas build:list`)
10. Run: `npx eas-cli submit --platform ios --non-interactive`
11. Call send_response("Build uploaded to TestFlight! Install to test.")
12. Session ends

## Environment
- Use EXPO_TOKEN from repo secrets for EAS authentication
- Use npx eas-cli (not global eas) to ensure correct version
```

### 4.6 EAS Build & Code Signing

**No manual signing needed.** EAS Build handles:
- Apple certificate generation/management
- Provisioning profile creation
- Xcode build on cloud macOS
- IPA generation and signing
- TestFlight upload via `eas submit`

**Apple Developer account**: `lalalic@139.com`, team ID `JABNLDLN8G`

**Per-app**: Each app gets a unique bundle ID (`com.neos.{slug}`). EAS auto-creates the App ID in Apple Developer portal on first build.

**Authentication**: `EXPO_TOKEN` (org-level GitHub secret) authenticates EAS CLI in GitHub Actions and coding agent VM.

### 4.7 Communication Bridge (Relay MCP → Phone)

The custom coding agent calls MCP tools on the relay throughout its lifecycle:

```
Agent picks up Issue #1
  → send_response("Starting work on tab navigation...")
  → user sees progress in Neox chat

Agent has a question
  → ask_user("Should Home show a grid or list?")
  → user answers on phone → relay returns answer → agent continues

Agent pushes code, creates PR
  → send_response("PR #1 created. CI running...")

CI passes → auto-merge
  → send_response("PR merged. Starting EAS Build...")
  → runs: eas build --platform ios
  → polls: eas build:list --status=in-progress

EAS Build completes
  → runs: eas submit --platform ios
  → send_response("Build #42 uploaded to TestFlight! Install to test.")
  → session ends
```

**No webhooks needed**: The agent drives the entire pipeline and reports via MCP.

**Session routing**: Relay maps `projectToken → userId → active session`. Offline messages queued for next connect.

---

## 5. User Flow (End-to-End)

### 5.1 Project Creation

```
User: "I want to build a recipe sharing app"

Agent (on phone):
  1. Asks clarifying questions via chat
  2. Decomposes into phases
  3. Calls create_task → creates repo neos/recipe-7f3a2b from template
  4. Creates Issue #1: "App scaffold with tab navigation"
  5. Reports: "Created your project! Coding agent starting..."
```

### 5.2 Coding Agent Works

```
Custom coding agent (GitHub cloud VM):
  1. Reads Issue #1 spec
  2. send_response("Working on tab navigation with Expo Router...")
  3. Implements: app/_layout.tsx, app/(tabs)/, components/
  4. Pushes code, creates PR
  5. CI passes → auto-merge
  6. eas build --platform ios → waits ~15 min
  7. eas submit --platform ios
  8. send_response("Build ready on TestFlight!")
```

### 5.3 Iteration Loop

```
User tests on phone → "The tab icons are too small"
  → Agent creates Issue #2 from feedback
  → Coding agent builds → TestFlight → repeat
```

---

## 6. Data Model

### 6.1 Project Registry (`projects.json`)

```json
{
  "projects": {
    "recipe-7f3a2b": {
      "repo": "neos/recipe-7f3a2b",
      "userId": "user-456",
      "displayName": "Recipe Sharing App",
      "bundleId": "com.neos.recipe-7f3a2b",
      "easProjectId": "xxx-xxx-xxx",
      "created": "2026-04-02T10:00:00Z",
      "status": "active",
      "lastBuild": null
    }
  }
}
```

### 6.2 Issue Spec Template

```markdown
## Goal
[One sentence: what should change]

## Context
[Files/modules involved, current behavior]

## Spec
- [ ] [Requirement 1]
- [ ] [Requirement 2]

## Constraints
- Expo SDK 53+, React Native, TypeScript
- Expo Router for navigation
- No ejecting from managed workflow
- No native modules unless absolutely necessary

## Validation
- [ ] `npx tsc --noEmit` passes
- [ ] `npm test` passes
- [ ] [Behavioral check]

## Out of Scope
[What NOT to touch]
```

---

## 7. Security & Isolation

| Concern | Mitigation |
|---------|------------|
| User code isolation | Each project is a separate repo; coding agent runs in isolated VM |
| EAS credentials | `EXPO_TOKEN` stored as org secret, never in code |
| Apple signing | EAS manages certs; never exposed to agent or user |
| Repo access | `lalalic1` bot account manages all repos; users have no GitHub access |
| API keys | User provides via chat → agent stores in EAS secrets (`eas secret:create`) |
| Cost control | Rate limit: one project per user, N builds per day |

---

## 8. Costs

| Service | Free Tier | Paid |
|---------|-----------|------|
| EAS Build | 30 builds/month | $99/month (unlimited) |
| GitHub Actions (CI) | 2,000 min/month (ubuntu) | $0.008/min |
| Apple Developer | — | $99/year |
| GitHub Copilot coding agent | Included with Copilot | — |

For MVP, free tiers are sufficient (30 EAS builds/month, ubuntu CI runners, Copilot included).

---

## 9. Limitations & Future Work

### MVP Limitations
- **TestFlight only** — no App Store submission
- **No push notifications** — requires APNs config
- **No backend** — client-only apps. Backend requires separate infrastructure
- **iOS only initially** — Android is easy to add with Expo later
- **EAS Build queue** — free tier builds may queue behind others (~5-20 min wait)

### Future Phases

| Phase | Feature |
|-------|---------|
| 2 | Android support (just add `--platform android` to build) |
| 2 | Expo Updates (OTA hotfixes without full rebuild) |
| 3 | Backend template (Supabase/Firebase) |
| 3 | App Store submission automation |
| 4 | User GitHub linking (fork to own account) |
| 4 | Marketplace (share/publish apps) |

---

## 10. Implementation Plan

### Phase 1: Foundation

1. Create GitHub org `neos` under `lalalic1`
2. Create `neos/expo-app-template` with Expo scaffold + workflows + agent config
3. Verify EAS Build works: `eas build --platform ios` from template
4. Verify `eas submit` uploads to TestFlight

### Phase 2: Relay Integration

5. Add `create_task` handler to relay-server.js (GitHub API: create repo, issue)
6. Add MCP endpoint to relay for coding agent communication
7. Add `projects.json` registry

### Phase 3: End-to-End

8. Create test issue in template repo, verify coding agent picks it up
9. Verify coding agent can call relay MCP tools
10. Run full pipeline: issue → code → PR → CI → merge → EAS Build → TestFlight
11. Hello World app on TestFlight

### Phase 4: Polish

12. Error handling (build failures, agent timeout)
13. Rate limiting
14. Project status view in Neox app

---

## 11. Open Questions

1. **Copilot coding agent + EAS CLI** — Can the cloud VM run `eas build`? Need `copilot-setup-steps.yml` to install Node.js + EAS CLI + set EXPO_TOKEN.
2. **EAS Build concurrency** — Free tier: 1 concurrent build. Multiple users will queue.
3. **App naming collisions** — Bundle IDs use `com.neos.{slug}` with random suffix to avoid conflicts.
4. **Cost model for users** — Per-build? Per-project? Subscription?
5. **Expo limitations** — Some features (e.g., Bluetooth, ARKit) require native modules. How to handle?
