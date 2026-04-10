# WeChat Bidirectional Integration Design

> **Date**: 2026-04-10  
> **Status**: Draft  
> **Goal**: Two scenarios — wire project discussions to WeChat rooms, and auto-reply as account owner

---

## Overview

Two new WeChat integration modes for Neox:

1. **Project Discussion Room** — Link a project to a WeChat group. Room members interact with the AI agent directly through WeChat.
2. **WeChat Assistant** — A template project type where the agent auto-replies to personal and group messages on behalf of the account owner.

Both build on the existing one-way bridge (agent → WeChat) by adding the **incoming direction** (WeChat → agent).

---

## Scenario 1: Project Discussion Room

### Concept

A Neox project is wired to a WeChat group chat. Participants discuss with the AI agent entirely in WeChat — no Neox app needed for them. The project owner manages setup and can override/steer from Neox.

### Setup Flow

```mermaid
sequenceDiagram
    actor Owner as Project Owner (Neox)
    participant Neox as Neox App
    participant WC as WeChat Bridge

    Owner->>Neox: Open project → "Wire to Room"
    Neox->>WC: Fetch room list
    WC-->>Neox: Available rooms
    Owner->>Neox: Pick room
    Neox->>Neox: Show member list
    Owner->>Neox: Assign roles (decision-maker / observer)
    Neox->>Neox: Save binding, start listening
```

### Message Flow

```mermaid
flowchart TB
    subgraph WeChat
        M[Room member sends message]
    end

    subgraph Neox["Neox (on owner's phone)"]
        B[WeChat Bridge captures message]
        R{Is sender a<br/>decision-maker?}
        Q{Pending<br/>ask_questions?}
        A[Route to project agent session]
        T[Resolve pending tool call]
        C[Add as context only]
        S[Agent generates response]
    end

    subgraph WeChat2[WeChat]
        O[Send response to room]
    end

    M --> B --> R
    R -->|Yes| Q
    R -->|No| C
    Q -->|Yes| T --> S
    Q -->|No| A --> S
    C --> A
    S --> O
```

### Roles

| Role | Can do | Example |
|------|--------|---------|
| **Decision-maker** | Answer `ask_questions`, approve tool calls, steer agent direction | Project lead, product manager |
| **Observer** | Messages become context for the agent, but don't resolve tool calls | Team members, stakeholders |
| **Owner** | Everything above + manage roles, override from Neox | The Neox user |

### UI Elements

**Project card badge:**
```
┌─────────────────────────────┐
│ 📱 My App Project           │
│ 💬 Wired: Marketing Room    │
│ 👥 3 decision-makers        │
└─────────────────────────────┘
```

**Room wiring sheet (in project settings):**
```
┌─ Wire to WeChat Room ──────────┐
│ Room: [Marketing Room ▼]       │
│                                │
│ Members:                       │
│ 🟢 John Zhang    [Decision ▼] │
│ 🔵 Alice Wang    [Decision ▼] │
│ ⚫ Bob Li        [Observer ▼] │
│ ⚫ Carol Chen    [Observer ▼] │
│                                │
│ [Start Listening]  [Cancel]    │
└────────────────────────────────┘
```

---

## Scenario 2: WeChat Assistant (Auto-Reply)

### Concept

A template project type. When the user creates a "WeChat Assistant" project, the agent monitors selected WeChat conversations and replies on behalf of the account owner — based on the owner's persona, context, and relationship with each contact.

### Setup Flow

```mermaid
sequenceDiagram
    actor Owner as Account Owner (Neox)
    participant Neox as Neox App
    participant WC as WeChat Bridge

    Owner->>Neox: Create project → "WeChat Assistant" template
    Neox->>Neox: Prompt for persona/rules
    Owner->>Neox: Configure persona + behavior rules
    Neox->>WC: Fetch contact list
    WC-->>Neox: Contacts + rooms
    Owner->>Neox: Select contacts to auto-reply
    Owner->>Neox: Set per-contact rules (optional)
    Neox->>Neox: Start listening
```

### Message Flow

```mermaid
flowchart TB
    subgraph WeChat
        M[Incoming message from contact]
    end

    subgraph Neox["Neox (owner's phone)"]
        B[WeChat Bridge captures message]
        F{Contact in<br/>auto-reply list?}
        I[Ignore]
        G{Needs owner<br/>approval?}
        A[Route to WeChat Assistant agent]
        S[Agent drafts reply as owner]
        N[Push notification to owner]
        AP{Owner<br/>approves?}
        E[Owner edits reply]
    end

    subgraph WeChat2[WeChat]
        O[Send reply as owner]
    end

    M --> B --> F
    F -->|No| I
    F -->|Yes| A --> S --> G
    G -->|No, safe to send| O
    G -->|Yes, needs review| N --> AP
    AP -->|Approve| O
    AP -->|Edit| E --> O
    AP -->|Reject| I
```

### Agent Context

The WeChat Assistant agent session receives:

- **Owner persona**: Role description, communication style, background
- **Contact context**: Relationship to contact, conversation history
- **Behavior rules**: What to commit to, what to escalate, tone preferences
- **Owner's role in rooms**: Whether owner is an admin, member, what topics owner leads

### Configuration UI

```
┌─ WeChat Assistant Setup ───────┐
│                                │
│ Your Persona:                  │
│ ┌──────────────────────────┐   │
│ │ Tech lead at ABC Corp.   │   │
│ │ Keep replies brief and   │   │
│ │ professional.            │   │
│ └──────────────────────────┘   │
│                                │
│ Behavior Rules:                │
│ ☑ Never schedule meetings      │
│ ☑ Don't commit to deadlines    │
│ ☑ Escalate money topics        │
│ ☐ Custom: ________________     │
│                                │
│ Auto-Reply Contacts:           │
│ [✓] John Zhang                 │
│ [✓] Marketing Room  (20 members) │
│ [ ] Alice Wang                 │
│                                │
│ [Start Auto-Reply]             │
└────────────────────────────────┘
```

### Guardrails

| Trigger | Action |
|---------|--------|
| Agent wants to make a promise or commitment | Push notification → owner approves/edits |
| Agent unsure about owner's position | Push notification → owner provides input |
| Contact asks about money, legal, scheduling | Escalate to owner |
| Routine question matching owner's persona | Auto-reply directly |

---

## Shared Infrastructure

### Bidirectional Bridge

```mermaid
flowchart LR
    subgraph WeChatBridge["WeChat Bridge (existing)"]
        direction TB
        OUT[sendMessage → WeChat]
        IN[onMessage ← WeChat]
    end

    subgraph Router["Message Router (new)"]
        direction TB
        RT{Route by<br/>contact/room ID}
        P1[Project A agent]
        P2[WeChat Assistant agent]
        P3[Unrouted → ignore]
    end

    IN --> RT
    RT --> P1
    RT --> P2
    RT --> P3
    P1 --> OUT
    P2 --> OUT
```

The existing `WeChatChannel.onMessage` callback is already wired but unused. The new **Message Router** maps incoming messages to the correct agent session.

### Contact-to-Project Mapping

```mermaid
erDiagram
    WECHAT_CONTACT {
        string id PK
        string name
        boolean isRoom
    }
    PROJECT {
        string id PK
        string name
        string type
    }
    CONTACT_BINDING {
        string contactId FK
        string projectId FK
        string role
        boolean autoReply
    }
    WECHAT_CONTACT ||--o{ CONTACT_BINDING : "bound to"
    PROJECT ||--o{ CONTACT_BINDING : "receives from"
```

A contact can be bound to at most one project. A project can have multiple bound contacts. The binding includes the role (for Scenario 1) and auto-reply flag (for Scenario 2).

### Data Model

```
~/.neo/wechat-routing.json
{
  "bindings": [
    {
      "contactId": "@@abc123",
      "contactName": "Marketing Room",
      "isRoom": true,
      "projectId": "proj-uuid-1",
      "role": "discussion-room",
      "members": {
        "john-id": { "name": "John Zhang", "role": "decision-maker" },
        "alice-id": { "name": "Alice Wang", "role": "decision-maker" },
        "bob-id":   { "name": "Bob Li",     "role": "observer" }
      }
    },
    {
      "contactId": "@friend123",
      "contactName": "John Zhang",
      "isRoom": false,
      "projectId": "proj-uuid-2",
      "role": "auto-reply"
    }
  ]
}
```

### What Needs Building

| Component | Description | Touches |
|-----------|-------------|---------|
| **WeChatRouter** | Routes incoming messages to correct agent session | New Swift file |
| **WeChatService** (update) | Manage bidirectional bridge, routing config | Existing service |
| **RoomWiringView** | Room selector + member role assignment UI | New SwiftUI view |
| **AssistantSetupView** | Persona, rules, contact selector for auto-reply | New SwiftUI view |
| **Contact binding persistence** | Load/save wechat-routing.json | New model |
| **Agent session integration** | Map incoming message → session.send with sender context | Update AgentCoordinator |
| **Decision-maker resolution** | Only decision-makers can answer ask_questions | Update tool call handling |
| **Owner approval flow** | Push notification + approve/edit/reject for sensitive replies | Update push handling |

### What Already Exists (no changes needed)

- `wechat-bro.js` — already captures all incoming messages with sender info
- `WeChatChannel` — has `onMessage` callback, `sendMessage()`, contact list
- `WeChatBridge` — JS evaluation, script loading
- Agent sessions via relay — `session.send` works for routing messages
- APNs push — already working for notifications

---

## Non-Goals (v1)

- Cross-device: WeChat bridge only works on the phone where Neox is running
- Voice messages: Text only in v1
- Image/file handling: Text messages only in v1
- Multi-language detection: Agent uses whatever language the contact writes in
- WeChat Pay or mini-program integration
