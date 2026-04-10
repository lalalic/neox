# WeChat Bidirectional Integration Design

> **Date**: 2026-04-10  
> **Status**: Draft  
> **Goal**: Two scenarios — project assistant via WeChat, and auto-reply as account owner

---

## Overview

Two new WeChat integration modes for Neox:

1. **Project Assistant** — Wire a project to a WeChat conversation (room or 1:1). The agent is a project assistant for everyone in the chat.
2. **WeChat Assistant** — A template project type where the agent auto-replies to personal and group messages on behalf of the account owner.

Both build on the existing one-way bridge (agent → WeChat) by adding the **incoming direction** (WeChat → agent).

---

## Scenario 1: Project Assistant

### Concept

A Neox project is wired to a WeChat conversation — either a **group room** or a **1:1 chat**. The agent's role is always the same: **project assistant** — executing tasks, answering questions, recording decisions, tracking action items, and driving the project forward.

The workflow is identical regardless of room or 1:1. The only difference is **who carries decision weight**. In a room, each member has a weight that determines how much authority their input carries (approve tool calls, steer direction, resolve `ask_questions`). In 1:1, the other person defaults to weight 50 — a strong voice but not full authority (owner retains final say from Neox).

### Setup Flow

```mermaid
sequenceDiagram
    actor Owner as Project Owner (Neox)
    participant Neox as Neox App
    participant WC as WeChat Bridge

    Owner->>Neox: Open project → "Wire to WeChat"
    Neox->>WC: Fetch contact list (rooms + people)
    WC-->>Neox: Available contacts
    Owner->>Neox: Pick room OR person
    alt Room selected
        Neox->>Neox: Show member list
        Owner->>Neox: Assign decision weight per member
    else Person selected
        Neox->>Neox: Auto-set: person weight = 50
    end
    Neox->>Neox: Save binding, start listening
```

### Message Flow

```mermaid
flowchart TB
    subgraph WeChat
        M[Someone sends message in chat]
        M2[Owner sends message in chat]
    end

    subgraph Neox["Neox (on owner's phone)"]
        B[WeChat Bridge captures message]
        L[Log to project conversation history]
        R[Routing sub-agent evaluates:<br/>sender weight + message content +<br/>conversation state + pending tool calls]
        D{Sub-agent<br/>decision}
        T[Resolve pending ask_questions]
        A[Send to project agent as new input]
        C[Store as context, no action]
        S[Project agent processes]
    end

    subgraph WeChat2[WeChat]
        O[Send 🤖 response to chat]
    end

    M --> B --> L --> R --> D
    M2 --> B
    D -->|"Answer pending question"| T --> S
    D -->|"New instruction/request"| A --> S
    D -->|"Context only"| C
    S --> O
```

A lightweight **routing sub-agent** decides how to handle each incoming message, instead of hard-coded threshold rules. It considers:

- **Sender weight** — who said it (PM vs intern)
- **Message content** — is it a question, instruction, casual chat, or answer to a pending question?
- **Conversation state** — is there a pending `ask_questions`? What was the agent working on?
- **Project context** — does this message change direction or just add info?

The sub-agent outputs one of three actions:
1. **Resolve pending tool call** — message answers a pending `ask_questions`  
2. **New agent input** — message is a new instruction or request for the project agent
3. **Context only** — store in history, no immediate action needed

### Owner Steering from Neox

The owner can also steer the system directly from the Neox app (not through WeChat). This creates two input channels:

```mermaid
flowchart LR
    subgraph Inputs
        WC[WeChat messages<br/>from participants]
        NX[Neox app<br/>owner input]
    end

    subgraph Routing["What receives the input?"]
        RS[Routing sub-agent]
        PA[Project agent directly]
    end

    WC --> RS
    NX -->|?| RS
    NX -->|?| PA
```

**Open question:** When the owner types something in Neox, where does it go?

| Option | Pros | Cons |
|--------|------|------|
| **A: Always to project agent** | Simple, owner has direct line to agent | Can't override routing sub-agent decisions |
| **B: Always to routing sub-agent** | Unified pipeline, consistent | Extra latency for direct instructions |
| **C: Context-dependent** | Best UX — Neox UI knows intent | More complex, needs UI signals |

Option C might work naturally: if the owner is in the project chat view → goes to project agent. If they're reviewing a pending `ask_questions` notification → resolves the tool call. If they're in the wiring settings → configures routing.

**Steering examples:**
- Owner sees agent heading wrong direction in WeChat → types correction in Neox → goes to project agent as override
- Owner gets push notification for pending `ask_questions` → taps to answer → resolves tool call
- Owner wants to mute a member temporarily → adjusts weight in wiring settings → affects routing sub-agent

### Agent Identity in WeChat

WeChat has no bot accounts — the agent sends messages using the **owner's identity**. To distinguish agent messages from the owner's own messages:

- **Prefix all agent messages** with a bot emoji: `🤖 ` (configurable)
- Example: `🤖 Based on the discussion, here are the action items...`
- The existing `wechat-bro.js` AI watermark (invisible Unicode marker) is also applied for programmatic detection via `isFromAI()`
- Owner's own manual messages have no prefix

This applies to both scenarios (project assistant and auto-reply).

---

### Decision Weight

Weight is a **signal** the routing sub-agent uses, not a hard threshold. Every participant has a weight (0–100) set by the project owner:

| Weight | Signal to sub-agent |
|--------|---------------------|
| **100** | Treat as authoritative — likely resolves questions, approves actions |
| **50–99** | Strong voice — worth acting on, especially if no higher-weight response |
| **1–49** | Contributor — valuable context, unlikely to be the final word |
| **0** | Muted — ignore entirely (only hard rule) |

**Owner** always has weight 100 (from Neox app, not through WeChat).

In **1:1 mode**, the other person defaults to weight 50.

In **room mode**, the project owner assigns weights when wiring. Example:
- Product manager: 100 (decision-maker)
- Lead engineer: 80 (strong voice)  
- Designer: 50 (can contribute meaningfully)
- Intern: 20 (context contributor)

The sub-agent uses weight alongside message content to make routing decisions. A weight-20 intern saying "the server is down" is still actionable. A weight-100 PM saying "lol nice" is just context. The AI handles nuance better than code thresholds.

### UI Elements

**Project card badge:**
```
┌─────────────────────────────┐
│ 📱 My App Project           │
│ 💬 Wired: Marketing Room    │
│ 👥 3 members (2 decision)   │
└─────────────────────────────┘

┌─────────────────────────────┐
│ 📱 Sales Proposal           │
│ 💬 Wired: John Zhang (1:1)  │
│ 🤝 Project assistant mode   │
└─────────────────────────────┘
```

**Wiring sheet (in project settings):**
```
┌─ Wire to WeChat ───────────────┐
│ Contact: [Marketing Room ▼]    │
│    or    [John Zhang ▼]        │
│                                │
│ If room selected:              │
│ Members:               Weight  │
│ 🟢 John Zhang    [━━━━━━ 100] │
│ 🔵 Alice Wang    [━━━━━░░ 80] │
│ ⚫ Bob Li        [━░░░░░░ 20] │
│                                │
│ If person selected:            │
│ John Zhang — weight 50         │
│ (strong voice, you keep final say)│
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
        int weight
        boolean autoReply
    }
    WECHAT_CONTACT ||--o{ CONTACT_BINDING : "bound to"
    PROJECT ||--o{ CONTACT_BINDING : "receives from"
```

A contact can be bound to at most one project. A project can have multiple bound contacts. The binding includes the weight (for Scenario 1) and auto-reply flag (for Scenario 2).

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
      "mode": "discussion-room",
      "members": {
        "john-id": { "name": "John Zhang", "weight": 100 },
        "alice-id": { "name": "Alice Wang", "weight": 80 },
        "bob-id":   { "name": "Bob Li",     "weight": 20 }
      }
    },
    {
      "contactId": "@colleague456",
      "contactName": "John Zhang",
      "isRoom": false,
      "projectId": "proj-uuid-1",
      "mode": "project-assistant",
      "weight": 50
    },
    {
      "contactId": "@friend123",
      "contactName": "Alice Wang",
      "isRoom": false,
      "projectId": "proj-uuid-2",
      "mode": "auto-reply"
    }
  ]
}
```

Three binding modes:
- `discussion-room` — Scenario 1 room: multi-party with per-member weights, agent is project assistant
- `project-assistant` — Scenario 1 person: 1:1, agent is project assistant with full access
- `auto-reply` — Scenario 2: agent replies as the account owner

### What Needs Building

| Component | Description | Touches |
|-----------|-------------|---------|
| **WeChatRouter** | Routes incoming messages to correct agent session | New Swift file |
| **WeChatService** (update) | Manage bidirectional bridge, routing config | Existing service |
| **RoomWiringView** | Room selector + member weight assignment UI | New SwiftUI view |
| **AssistantSetupView** | Persona, rules, contact selector for auto-reply | New SwiftUI view |
| **Contact binding persistence** | Load/save wechat-routing.json | New model |
| **Agent session integration** | Map incoming message → session.send with sender context | Update AgentCoordinator |
| **Routing sub-agent** | Lightweight LLM call to classify incoming messages | New component |
| **Decision weight resolution** | Sub-agent uses weight as signal for routing decisions | Part of routing sub-agent |
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
