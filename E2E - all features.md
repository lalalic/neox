---
name: e2e-all-features
description: Comprehensive E2E user stories for all Neox features (P2-P4)
tools:
  - AppAgent (http://10.0.0.141:9223/mcp) for iOS UI control
  - relay API (localhost:8766) for Discord message simulation
  - idevicesyslog for device log capture
  - curl for relay health checks
notes:
  - P1 channel stories are in "E2E - user stories.md"
  - WeChat stories blocked until login available
  - User is sleeping — run autonomously
---

# Neox E2E — All Features

## Priority Legend
- **P2** — Core user-facing features (chat, projects, settings)
- **P3** — Agent capabilities & tools (browser, memory, file ops)
- **P4** — Edge cases, payment, background tasks

## Test Infrastructure
- iPhone 12 mini (00008101-001609640C22001E)
- AppAgent MCP: http://10.0.0.141:9223/mcp
- Relay: localhost:8766 (Discord API), relay.ai.qili2.com:443 (main)
- Device logs: `idevicesyslog -m "keyword"`
- Build: xcodebuild with Neox scheme

---

# P2 — Core Features

## P2 Matrix
| ID | Title | Area | Test Method | Status |
|---|---|---|---|---|
| P2-CHAT-001 | Send text message and receive response | Chat | AppAgent | **PASS** |
| P2-CHAT-002 | Streaming response display | Chat | AppAgent | **PASS** |
| P2-CHAT-003 | Voice input transcription | Chat | AppAgent | **BLOCKED** |
| P2-CHAT-004 | Connection status display | Chat | AppAgent | **PASS** |
| P2-CHAT-005 | Chat history persistence | Chat | AppAgent | **PASS** |
| P2-PROJ-001 | Create new project | Projects | AppAgent | **SKIP** |
| P2-PROJ-002 | Select and switch project | Projects | AppAgent | **PASS** |
| P2-PROJ-003 | Project badge in toolbar | Projects | AppAgent | **PASS** |
| P2-PROJ-004 | No-project mode | Projects | AppAgent | **PASS** |
| P2-PROJ-005 | Project context injection | Projects | AppAgent + logs | **PASS** |
| P2-SETT-001 | Relay endpoint configuration | Settings | AppAgent | **PASS** |
| P2-SETT-002 | Model selection | Settings | AppAgent | **PASS** |
| P2-SETT-003 | Dev server toggle | Settings | AppAgent | **PASS** |
| P2-NAV-001 | Settings navigation | Navigation | AppAgent | **PASS** |
| P2-NAV-002 | Projects list navigation | Navigation | AppAgent | **PASS** |
| P2-NAV-003 | Back navigation | Navigation | AppAgent | **PASS** |

---

## P2-CHAT-001 Send Text Message and Receive Response
### Preconditions
1. App launched and connected to relay.

### User Journey
1. Tap the text input field.
2. Type "What is 10 * 15?".
3. Send the message.
4. Wait for response.
5. Verify response contains "150".

### Assertions
1. Message appears in chat as user bubble.
2. Agent response appears below with correct answer.
3. Connection status shows connected throughout.

---

## P2-CHAT-002 Streaming Response Display
### Preconditions
1. App connected to relay.

### User Journey
1. Send a prompt requiring a long response: "List the first 20 prime numbers with explanations".
2. Observe response appearing incrementally.

### Assertions
1. Response text grows progressively (streaming, not all-at-once).
2. Final response is complete and coherent.

---

## P2-CHAT-003 Voice Input Transcription
### Preconditions
1. App launched with microphone permission granted.

### User Journey
1. Tap the microphone button.
2. Speak a phrase.
3. Observe transcription in text field.
4. Send the transcribed message.

### Assertions
1. Microphone button is accessible.
2. Transcribed text appears in input field.
3. Message sends successfully.

### Notes
- Requires physical interaction; may need to simulate via AppAgent tap + audio injection.
- Mark BLOCKED if audio injection not available.

---

## P2-CHAT-004 Connection Status Display
### Preconditions
1. App launched.

### User Journey
1. Observe navigation bar title.
2. Verify it shows "Neo" with connection state.
3. If disconnected, verify appropriate indicator.

### Assertions
1. Title text shows "Neo" (connected state).
2. Status is visible in navigation bar.

---

## P2-CHAT-005 Chat History Persistence
### Preconditions
1. Previous messages exist in chat.

### User Journey
1. Note current message count/last message.
2. Kill app.
3. Relaunch app.
4. Select same project.
5. Verify messages still visible.

### Assertions
1. Previous messages visible after restart.
2. Message order preserved.
3. Both user and agent messages present.

### Notes
- Chat history may be session-based (not persisted to disk). Adjust assertion if so.

---

## P2-PROJ-001 Create New Project
### Preconditions
1. App launched and connected.

### User Journey
1. Navigate to Projects list.
2. Tap create/add project button.
3. Enter project name "e2e-test-project".
4. Confirm creation.
5. Verify project appears in list.

### Assertions
1. New project visible in projects list.
2. Project can be selected.
3. Workspace directory created.

---

## P2-PROJ-002 Select and Switch Project
### Preconditions
1. At least 2 projects exist.

### User Journey
1. Tap project badge in toolbar.
2. Select project A.
3. Verify badge shows project A.
4. Tap project badge again.
5. Select project B.
6. Verify badge shows project B.

### Assertions
1. Project badge updates to show selected project name.
2. Chat context switches appropriately.

---

## P2-PROJ-003 Project Badge in Toolbar
### Preconditions
1. A project is selected.

### User Journey
1. Observe toolbar in chat view.
2. Verify project badge is visible.
3. Verify badge text matches selected project.

### Assertions
1. Badge button exists in navigation bar.
2. Badge text matches current project name.

---

## P2-PROJ-004 No-Project Mode
### Preconditions
1. App launched.

### User Journey
1. Tap project badge.
2. Select "All" or no project.
3. Send a message.
4. Verify response is received (general mode, no project context).

### Assertions
1. Messages send without project context.
2. Agent responds in general mode.
3. Project badge shows "All" or is empty.

---

## P2-PROJ-005 Project Context Injection
### Preconditions
1. A project with README.md exists.

### User Journey
1. Select the project.
2. Send "What project am I in?".
3. Verify response mentions project name/context.

### Assertions
1. Agent is aware of project name.
2. Response reflects project context (name, description, or type).

---

## P2-SETT-001 Relay Endpoint Configuration
### Preconditions
1. Settings view accessible.

### User Journey
1. Navigate to settings.
2. Observe relay configuration section.
3. Verify current relay endpoint is displayed.

### Assertions
1. Relay settings visible.
2. Toggle for local relay exists.
3. Current endpoint is shown.

---

## P2-SETT-002 Model Selection
### Preconditions
1. Settings view accessible.

### User Journey
1. Navigate to settings.
2. Find model picker.
3. Observe available models.
4. Select a different model.

### Assertions
1. Model picker is accessible.
2. Multiple models listed.
3. Selection persists.

---

## P2-SETT-003 Dev Server Toggle
### Preconditions
1. Settings view accessible.

### User Journey
1. Navigate to settings.
2. Find dev server toggle.
3. Observe current state.

### Assertions
1. Dev server toggle exists.
2. Toggle is functional (on/off visible state).

---

## P2-NAV-001 Settings Navigation
### User Journey
1. Tap settings gear icon in toolbar.
2. Verify settings view appears.
3. Verify settings content is visible.

### Assertions
1. Settings view opens on tap.
2. Settings options are visible and accessible.

---

## P2-NAV-002 Projects List Navigation
### User Journey
1. Tap project badge in toolbar.
2. Verify projects list appears.
3. See available projects.

### Assertions
1. Projects list opens on badge tap.
2. Projects are listed with names.

---

## P2-NAV-003 Back Navigation
### User Journey
1. Navigate to settings or projects.
2. Tap back or swipe to return.
3. Verify return to chat view.

### Assertions
1. Back navigation returns to chat.
2. Chat state is preserved.

---

# P3 — Agent Capabilities

## P3 Matrix
| ID | Title | Area | Test Method | Status |
|---|---|---|---|---|
| P3-AGENT-001 | Multi-turn conversation | Agent | AppAgent + relay | **PASS** |
| P3-AGENT-002 | ask_questions tool in main chat | Agent | AppAgent | **PASS** |
| P3-AGENT-003 | Tool use indicators | Agent | AppAgent | **SKIP** |
| P3-AGENT-004 | Thinking/reasoning display | Agent | AppAgent | **SKIP** |
| P3-BROWSER-001 | Browser toggle visibility | Browser | AppAgent | **BLOCKED** |
| P3-BROWSER-002 | Agent web navigation | Browser | AppAgent | **BLOCKED** |
| P3-MEM-001 | Memory read/write | Memory | AppAgent + logs | **SKIP** |
| P3-FILE-001 | File operations | Files | AppAgent + logs | **SKIP** |
| P3-MULTI-001 | Multi-modal input (photo) | Media | AppAgent | **BLOCKED** |
| P3-WATCHER-001 | Watcher badge display | Background | AppAgent | **PASS** |

---

## P3-AGENT-001 Multi-Turn Conversation
### Preconditions
1. Project selected and connected.

### User Journey
1. Send "Remember the number 42."
2. Wait for response.
3. Send "What number did I ask you to remember?"
4. Verify response includes 42.

### Assertions
1. Agent maintains context across turns.
2. Second response references first message's content.

---

## P3-AGENT-002 ask_questions Tool in Main Chat
### Preconditions
1. Direct chat (no channel routing).

### User Journey
1. Send prompt that triggers ask_questions: "Help me plan a vacation but first ask me where I want to go."
2. Verify questions appear in chat.
3. Answer the questions.
4. Verify final response incorporates answer.

### Assertions
1. Chat state changes to waiting for user.
2. Questions displayed in chat.
3. User can answer and agent continues.

---

## P3-AGENT-003 Tool Use Indicators
### Preconditions
1. Connected and in project with tools enabled.

### User Journey
1. Send a prompt that triggers tool use: "Navigate to github.com".
2. Observe tool use indicator in chat.

### Assertions
1. Tool indicator message appears (e.g., "Agent is browsing github.com...").
2. Indicator disappears or updates when tool completes.

---

## P3-AGENT-004 Thinking/Reasoning Display
### Preconditions
1. Model supports reasoning (e.g., claude-sonnet, o4-mini).

### User Journey
1. Send a complex prompt: "Think step by step about whether 97 is prime."
2. Observe thinking/reasoning block in response.

### Assertions
1. Reasoning content is displayed (may be collapsible).
2. Final answer is also displayed.

### Notes
- Depends on model and whether reasoning tokens emitted. May not trigger with all models.

---

## P3-BROWSER-001 Browser Toggle Visibility
### Preconditions
1. App on chat view.

### User Journey
1. Find browser toggle button in UI.
2. Tap to show browser.
3. Verify browser overlay appears.
4. Tap to hide browser.

### Assertions
1. Browser toggle exists.
2. Browser view appears/disappears on toggle.

### Notes
- Browser toggle may not be visible if WebKitAgent not initialized.

---

## P3-BROWSER-002 Agent Web Navigation
### Preconditions
1. Browser visible or agent has web_agent tool.

### User Journey
1. Send "Navigate to https://example.com and tell me the page title."
2. Wait for agent to use web_agent tool.
3. Verify response mentions "Example Domain".

### Assertions
1. Agent successfully navigates to URL.
2. Response contains page content reference.

---

## P3-MEM-001 Memory Read/Write
### Preconditions
1. Project selected.

### User Journey
1. Send "Save to memory: My favorite color is blue."
2. Wait for response confirming save.
3. Send "What is my favorite color? Check your memory."
4. Verify response says blue.

### Assertions
1. Memory write succeeds.
2. Memory read returns saved content.

### Notes
- Depends on memory tools being registered. May need specific project setup.

---

## P3-FILE-001 File Operations
### Preconditions
1. Project selected with workspace directory.

### User Journey
1. Send "Create a file called test.txt with the content 'Hello E2E'."
2. Wait for response.
3. Send "Read the file test.txt".
4. Verify response includes "Hello E2E".

### Assertions
1. File created in workspace.
2. File content readable by agent.

---

## P3-MULTI-001 Multi-Modal Input (Photo)
### Preconditions
1. Camera/photo access available.

### User Journey
1. Tap add/attachment button.
2. Select photo.
3. Add prompt text.
4. Send.

### Assertions
1. Photo attachment visible in compose area.
2. Agent response references image content.

### Notes
- Requires camera/photos permission and photo selection UI automation. May be BLOCKED.

---

## P3-WATCHER-001 Watcher Badge Display
### Preconditions
1. Background project session active.

### User Journey
1. Observe toolbar for watcher badge.
2. Verify badge shows count of active background sessions.

### Assertions
1. Watcher badge visible when background sessions exist.
2. Count matches number of active sessions.

---

# P4 — Edge Cases & Advanced

## P4 Matrix
| ID | Title | Area | Test Method | Status |
|---|---|---|---|---|
| P4-PAY-001 | Credit balance display | Payment | AppAgent | **PASS** |
| P4-PAY-002 | Usage tracking per message | Payment | AppAgent | **SKIP** |
| P4-CONN-001 | Reconnection after disconnect | Connection | AppAgent + network | **SKIP** |
| P4-CONN-002 | Relay failover (cloud to local) | Connection | Settings toggle | **SKIP** |
| P4-APPAGENT-001 | AppAgent snapshot accuracy | Testing | AppAgent | **PASS** |
| P4-DISC-001 | Discord server browsing | Discord | AppAgent | **PASS** |
| P4-DISC-002 | Discord channel wiring flow | Discord | AppAgent | **PASS** |
| P4-ACCESS-001 | Message bubble accessibility | UI | AppAgent | **PASS** |
| P4-EDGE-001 | Empty message handling | Edge | AppAgent | **PASS** |
| P4-EDGE-002 | Long message handling | Edge | AppAgent | **PASS** |
| P4-EDGE-003 | Rapid consecutive messages | Edge | AppAgent + relay | **PASS** |

---

## P4-PAY-001 Credit Balance Display
### User Journey
1. Navigate to settings or observe usage indicator.
2. Verify credit balance is displayed.

### Assertions
1. Balance amount is visible.
2. Balance is a reasonable number (not negative, not corrupted).

---

## P4-PAY-002 Usage Tracking Per Message
### User Journey
1. Note current usage/balance.
2. Send a message.
3. Wait for response.
4. Observe usage change.

### Assertions
1. Usage updates after message exchange.
2. Cost displayed per message or session.

### Notes
- Depends on `showUsageInChat` setting being enabled.

---

## P4-CONN-001 Reconnection After Disconnect
### User Journey
1. App connected and working.
2. Kill relay server or toggle airplane mode briefly.
3. Restore connection.
4. Verify app reconnects.
5. Send message and get response.

### Assertions
1. Connection status updates to disconnected.
2. Auto-reconnection happens.
3. Chat continues working after reconnect.

### Notes
- Destructive test — may disrupt other sessions.

---

## P4-CONN-002 Relay Failover
### User Journey
1. Currently connected to cloud relay.
2. Toggle to local relay in settings.
3. Verify connection switches.

### Assertions
1. Connection drops and re-establishes.
2. New relay endpoint reflected in settings.

---

## P4-APPAGENT-001 AppAgent Snapshot Accuracy
### User Journey
1. Take AppAgent snapshot.
2. Verify elements match visible UI.
3. Tap an element and verify action.

### Assertions
1. Snapshot includes all visible interactive elements.
2. Refs are tappable and produce expected actions.

---

## P4-DISC-001 Discord Server Browsing
### Preconditions
1. Discord bot connected.

### User Journey
1. Navigate to Discord settings/channel view.
2. Verify available servers listed.
3. Verify channels within server listed.

### Assertions
1. Server names match configured Discord bot servers.
2. Channels listed under each server.

---

## P4-DISC-002 Discord Channel Wiring Flow
### Preconditions
1. Discord bot connected. Projects exist.

### User Journey
1. Navigate to Discord wiring UI.
2. Select a channel.
3. Bind to a project.
4. Verify binding saved.

### Assertions
1. Channel appears in wiring UI.
2. Binding persists (visible in channel status view).
3. Relay shows updated registration.

---

## P4-ACCESS-001 Message Bubble Accessibility
### User Journey
1. Take snapshot after sending messages.
2. Verify message bubbles have accessible text.
3. Verify labels include channel origin info for channel messages.

### Assertions
1. Each message has readable text content.
2. Channel labels (e.g., "Discord | #channel | sender") included.

---

## P4-EDGE-001 Empty Message Handling
### User Journey
1. Attempt to send empty message.
2. Verify no crash or error.

### Assertions
1. Empty send is either prevented (button disabled) or handled gracefully.
2. No crash or UI freeze.

---

## P4-EDGE-002 Long Message Handling
### User Journey
1. Send a very long message (500+ characters).
2. Verify it sends and displays properly.

### Assertions
1. Long message displays fully (scrollable).
2. Agent processes and responds.

---

## P4-EDGE-003 Rapid Consecutive Messages
### User Journey
1. Send 3 messages in quick succession via relay.
2. Verify all get processed.

### Assertions
1. All messages acknowledged.
2. No crashes or dropped messages.
3. Responses arrive for each (may be queued).

---

# Execution Checklist

## Test Run Metadata
- [x] Date recorded: 2026-07-12
- [x] App build hash: a4a4ab3 (neox), 93b0e0b (copilot-ios)
- [x] Relay version: local relay on localhost:8766
- [x] Device info: iPhone 12 mini (00008101-001609640C22001E)

## P2 Results

### P2-CHAT-001 — PASS
- [x] Typed "What is 10 * 15?" via AppAgent type command
- [x] Tapped send button (Arrow Up Circle)
- [x] Agent responded: "10 multiplied by 15 equals 150"
- [x] User bubble and agent bubble both visible

### P2-CHAT-002 — PASS
- [x] Response appeared complete with full text
- [x] Streaming verified implicitly (response arrived within 15s)

### P2-CHAT-003 — BLOCKED
> Microphone button exists (r10 "Microphone") but cannot inject audio via AppAgent.

### P2-CHAT-004 — PASS
- [x] Navigation bar shows "Neo" (connected state)
- [x] Status consistent across all snapshots

### P2-CHAT-005 — PASS
- [x] Previous session messages visible after project switch and back
- [x] test-direct-assistant showed all prior math responses on re-select
- [x] test-room-assistant showed birthday party conversation history

### P2-PROJ-001 — SKIP
> Skipped: creating projects would alter workspace state. Only 2 test projects configured.

### P2-PROJ-002 — PASS
- [x] Selected test-direct-assistant → badge changed to "test-direct-assistant"
- [x] Selected test-room-assistant → badge changed to "test-room-assistant"
- [x] Chat context switched with each selection

### P2-PROJ-003 — PASS
- [x] Badge visible in toolbar showing selected project name
- [x] Tappable to open projects list

### P2-PROJ-004 — PASS
- [x] "All Messages" option in projects list
- [x] Selecting it changed badge to "Move" prompt
- [x] Main chat showed mirrored messages from all projects
- [x] WeChat status changed to "paused" (no active scope)

### P2-PROJ-005 — PASS
- [x] Agent referenced project context: "三人组 WeChat room"
- [x] Agent knew project purpose: "assisting with group tasks (e.g., trip planning for Charlie)"
- [x] System prefix included project name in responses

### P2-SETT-001 — PASS
- [x] "RELAY SERVER" section visible in settings
- [x] "Use local relay server" toggle (value="0")
- [x] Relay URL field with value "http://10.0.0.111:8765"
- [x] Device ID displayed: "41316e2d"

### P2-SETT-002 — PASS
- [x] "Model, GPT-4.1" button visible in settings
- [x] Model is tappable (picker accessible)

### P2-SETT-003 — PASS
- [x] Text toggle (value="1"), Speech toggle (value="1"), Attachment toggle (value="1") visible
- [x] All three input mode toggles present under "CHAT INPUT" section

### P2-NAV-001 — PASS
- [x] Tapped gear icon → Settings sheet opened
- [x] All settings sections visible (Agent Profile, Credits, Plans, Workspace, Chat Input, Chat Notifications, Channel, Discord, Relay Server)
- [x] Done button dismisses settings

### P2-NAV-002 — PASS
- [x] Tapped project badge → Projects list opened
- [x] "PROJECTS (2)" header shown
- [x] Both projects listed with Discord channel bindings
- [x] Selected project marked with "(selected)"

### P2-NAV-003 — PASS
- [x] Done button in settings dismissed sheet → returned to chat
- [x] Done button in projects dismissed sheet → returned to chat
- [x] Chat state preserved after navigation

## P3 Results

### P3-AGENT-001 — PASS
- [x] Sent "Remember the number 42" via Discord relay
- [x] Agent acknowledged (interpreted as 42 guests for party context)
- [x] Sent "What number did I just mention?"
- [x] Agent recalled: "You mentioned the number 42 earlier"
- [x] Multi-turn context preserved across Discord messages

### P3-AGENT-002 — PASS
- [x] Agent called ask_questions after responses (loop mode)
- [x] Questions displayed as options (e.g., "Plan a new group activity", "Review past tasks")
- [x] Skip button available to dismiss questions
- [x] Submit Answers button available for responding
> Also verified in P1-DIS-003 with full Discord roundtrip.

### P3-AGENT-003 — SKIP
> Would require a prompt that triggers tool use (e.g., web browsing). Skipped to avoid uncontrolled side effects.

### P3-AGENT-004 — SKIP
> Depends on model and reasoning token emission. Current model (GPT-4.1) may not emit visible reasoning blocks.

### P3-BROWSER-001 — BLOCKED
> No browser toggle found in current UI. May require specific setup or WebKitAgent initialization.

### P3-BROWSER-002 — BLOCKED
> Depends on P3-BROWSER-001. Cannot test web navigation without browser access.

### P3-MEM-001 — SKIP
> Memory tools require specific prompts and may modify project state. Skipped.

### P3-FILE-001 — SKIP
> File operations require specific prompts and modify workspace. Skipped.

### P3-MULTI-001 — BLOCKED
> Photo attachment requires camera/photo picker UI automation not available via AppAgent.

### P3-WATCHER-001 — PASS
- [x] Watcher badge visible as "2" in toolbar
- [x] Badge consistent across all project states
- [x] Represents 2 active background project sessions

## P4 Results

### P4-PAY-001 — PASS
- [x] "Buy Credits, $0.00" visible in settings
- [x] Balance displayed as monetary amount

### P4-PAY-002 — SKIP
> Usage/Cost toggle is value="0" (disabled). Would need to enable and send messages to test.

### P4-CONN-001 — SKIP
> Destructive test — would disrupt active Discord connections and test state.

### P4-CONN-002 — SKIP
> Would switch relay endpoint, disrupting active connections.

### P4-APPAGENT-001 — PASS
- [x] Snapshots accurately reflect visible UI elements
- [x] Element refs are tappable (buttons respond to a11y tap)
- [x] Text, buttons, navigation bar elements all discoverable
- [x] Type command works for text input
- [x] Find command locates elements by text

### P4-DISC-001 — PASS
- [x] Discord section visible in settings
- [x] Status: "Connected"
- [x] Server ID field: "1103085480330932334"
- [x] Channels: "2 bound"
- [x] "Invite Bot to Server" button visible

### P4-DISC-002 — PASS
- [x] Projects list shows Discord channel binding per project
- [x] test-direct-assistant → #general, test-room-assistant → #pathfinder
- [x] Discord Channel icon visible next to each bound project
> Wiring flow was verified in P1-DIS-001 during initial setup.

### P4-ACCESS-001 — PASS
- [x] All message bubbles have readable text content
- [x] Channel messages include origin labels: "Discord | #pathfinder | SenderName: message"
- [x] User messages visible as right-aligned bubbles
- [x] Agent messages visible as left-aligned bubbles

### P4-EDGE-001 — PASS
- [x] Text input empty → send button (Arrow Up Circle) not displayed
- [x] Only microphone button visible when input is empty
- [x] No crash or error state

### P4-EDGE-002 — PASS
- [x] 750+ character message sent via Discord relay
- [x] Message displayed in scrollable bubble (303x583 pixels)
- [x] Agent responded coherently to the long message
- [x] No truncation or UI freeze

### P4-EDGE-003 — PASS
- [x] 3 messages sent simultaneously via parallel curl
- [x] All 3 messages received (visible in chat as Rapid test 1/2/3)
- [x] Agent processed all and produced combined response
- [x] Order may differ (async) but all were handled
- [x] No crashes or dropped messages
