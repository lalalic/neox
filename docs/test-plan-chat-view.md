# Neox Chat View — Scenario Test Plan

## Latest Execution Results (AppAgent + MCP)

Date: 2026-03-30
Device: iPhone 17 (physical)
Endpoint: http://10.0.0.81:9223/mcp

### Passed
- T1.1 Cold launch stable (no crash)
- T2.1–T2.3 Text input/send/assistant response
- T8.1 ask_user waiting state shown
- T8.3 ask_user answer via text resumes loop
- AQ.1 ask_questions state entered (new feature)
- AQ.2 ask_questions submit button flow works and state exits waitingForQuestions
- T10.1–T10.2 Web/chat toggle works (Globe ↔ Comment Left)
- T9.2 Attachment picker opens (Photo Library + Files visible)
- T15.1 AppAgent screenshot returns image payload
- T15.2 AppAgent snapshot returns accessibility tree
- T11.1–T11.4 Settings sheet controls verified (Relay Server section + presets)

### Failed / Needs follow-up
- T11.5 Reconnect path previously dropped chat to disconnected (fixed in code; needs clean rerun confirmation)

### Blocked in this run
- T3.* Speech quality/permission scenarios require live microphone interaction
- T9.3–T9.12 file/photo selection completion needs manual picker interaction beyond current AppAgent control
- Several later UI checks became blocked once attachment sheet remained presented (AppAgent could open it reliably but dismissal control was not discoverable)

### Notes
- `connected: false` in `get_status` remained inconsistent with actual message exchange success (send/receive worked through relay). This appears to be a status-reporting issue in `connectionManager` exposure, not transport failure.

## Prerequisites
- iPhone 17 device, app installed
- Local relay server running on 10.0.0.111:8765
- AppAgent MCP server accessible from Mac (port 9223)
- copilot CLI pool connected to relay

## Test Categories

### T1 — App Launch & Connection
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T1.1 | Cold launch | Kill app → Launch | App opens to chat view, shows "Connecting..." briefly, then idle. No crash. |
| T1.2 | Relay connection | Launch with relay running | Status dot turns green, "Connecting" banner clears within 3s |
| T1.3 | Relay down | Kill relay → Launch app | Shows "Connecting..." banner persistently. Error banner may appear. |
| T1.4 | Relay recovery | T1.3 → restart relay | Connection auto-recovers, status turns green |

### T2 — Text Input & Sending
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T2.1 | Type message | Tap input → type "hello" | Text appears in input field, send button becomes active (blue) |
| T2.2 | Send message | T2.1 → tap send | Message appears as blue user bubble on right. Input clears. |
| T2.3 | Agent response | T2.2 → wait | Assistant bubble appears on left with response. Streaming dots shown during generation. |
| T2.4 | Empty send guard | Tap send with empty input | Send button should be disabled/greyed |
| T2.5 | Multi-line input | Type text with newlines | Input field expands (up to 5 lines), text wraps properly |
| T2.6 | Long message | Type 500+ char message → send | Message renders fully, scrollable |

### T3 — Voice Input (Speech)
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T3.1 | Mic button visible | Open chat (idle, empty input) | Mic button shown (when text empty, speech enabled) |
| T3.2 | Start listening | Tap mic button | Red pulsing dot appears, speech recognition starts |
| T3.3 | Partial transcription | T3.2 → speak words | Text appears in input field in real-time |
| T3.4 | Auto-send on finish | T3.2 → speak → pause | After pause, final transcription sent automatically |
| T3.5 | Stop manually | T3.2 → tap stop button | Listening stops, transcribed text remains in input |
| T3.6 | Permission denied | Deny speech permission | Mic button present but gracefully handles denial |

### T4 — Message Display & Content Types
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T4.1 | Plain text | Send "what is 2+2" | Response renders as text bubble |
| T4.2 | Markdown | Ask for formatted answer | Bold, italic, headers, links render correctly |
| T4.3 | Code block | Ask "write hello world in python" | Code block with language label, monospace font, Copy button |
| T4.4 | Code copy button | T4.3 → tap Copy | Shows "Copied" confirmation, code in clipboard |
| T4.5 | Streaming display | Send any prompt → observe | Dots animate during streaming, text appears token by token |
| T4.6 | Multiple messages | Send 5+ messages | All messages visible, scroll works, auto-scroll to bottom |
| T4.7 | Text selection | Long-press on message text | Text selection handles appear, can copy |

### T5 — Tool Activity Panel
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T5.1 | Panel appears | Send prompt that triggers tools | Tool activity panel appears showing running tools |
| T5.2 | Tool progress | Observe during tool execution | Spinner icon for running, checkmark for completed |
| T5.3 | Expand/collapse | Tap tool activity header | Panel toggles between expanded and collapsed |
| T5.4 | Tool result preview | T5.2 after completion | Shows truncated result text per tool |

### T6 — Todo Panel
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T6.1 | Todo visible | Agent uses manage_todo_list | Todo panel appears above input with tasks |
| T6.2 | Status icons | Observe todo items | ○ for not-started, ● for in-progress, ✓ for completed |
| T6.3 | Progress bar | Observe during task progress | Blue progress bar fills proportionally |
| T6.4 | Expand/collapse | Tap "Tasks" header | Panel toggles visibility |

### T7 — Steering (Mid-conversation Inject)
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T7.1 | Steer placeholder | While agent is working (tools running) | Input placeholder changes to "Steer...", blue border |
| T7.2 | Send steer text | T7.1 → type "focus on file tools only" → send | Steer delivered, agent adjusts. User message appears in chat. |
| T7.3 | Steer while streaming | Agent mid-response → type steer → send | Agent receives steer, may adjust current response or next turn |
| T7.4 | Multiple steers | Send 3 steers in rapid succession while agent works | All steers delivered without crash or UI freeze |
| T7.5 | Steer with speech | While agent working → tap mic → speak steer | Voice input works in working state, steer sent on completion |
| T7.6 | Steer input enabled | Verify input field is enabled during 'working' state | Can type and send. Not greyed out. |
| T7.7 | Steer vs prompt | Send steer → wait for idle → send normal prompt | Steer goes as steer, next message goes as normal prompt |

### T8 — ask_user Flow (Answer Questions)
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T8.1 | Question display | Agent calls ask_user with a question | Question appears as assistant message. Input gets orange border. |
| T8.2 | Placeholder shows question | T8.1 observe input | Input placeholder shows truncated question text (~50 chars) |
| T8.3 | Reply via text | T8.1 → type answer → send | Answer delivered, agent continues. State returns to working/idle. |
| T8.4 | Reply via speech | T8.1 → tap mic → speak answer | Speech transcription sent as answer. Agent resumes. |
| T8.5 | Long question truncation | Agent asks question longer than 50 chars | Placeholder truncated with "..." |
| T8.6 | Multiple rounds | Agent asks → user answers → agent asks again | Each ask_user cycle works, orange border toggles correctly |
| T8.7 | Answer after app background | ask_user → background app → resume → answer | Question still visible, can still answer |
| T8.8 | Empty answer guard | ask_user pending → try sending empty text | Send button should be disabled for empty text |

> `ask_questions` is now implemented with structured options, multi-select, and freeform support.

### T9 — Attachments & Images
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T9.1 | Paperclip visible | Open chat in idle state | Paperclip button visible in input bar (left side) |
| T9.2 | Open attachment picker | Tap paperclip | Sheet appears with "Photo Library" and "Files" options |
| T9.3 | Select photo from library | T9.2 → Photo Library → select a photo | Photo selected, sheet dismisses. Attachment indicator in input? |
| T9.4 | Select file | T9.2 → Files → choose a PDF or text file | File selected, sheet dismisses |
| T9.5 | Send with photo | T9.3 → type "describe this image" → send | Photo sent with text. User message shows image. Agent describes it. |
| T9.6 | Send photo only | T9.3 → send without text | Photo sent. Agent receives and processes image. |
| T9.7 | Cancel picker | T9.2 → tap outside sheet or cancel | Sheet dismisses, no attachment added |
| T9.8 | Image in response | Agent sends image data in response | Inline image renders in assistant bubble, max width 250, rounded corners |
| T9.9 | Attachment chip | Agent sends attachment ref | Attachment chip with doc icon + filename displayed |
| T9.10 | Large image handling | Select 4K photo → send | Image resized/compressed properly, doesn't crash or hang |
| T9.11 | Multiple attachments | Select photo → send → select another → send | Both work independently |
| T9.12 | Paperclip in ask_user | In waitingForUser state → tap paperclip | Attachment picker works while answering question |

### T10 — Web View Toggle
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T10.1 | Toggle to web | Tap globe button (top-right) | Web view appears, chat hides |
| T10.2 | Toggle to chat | T10.1 → tap chat bubble button | Chat returns, web view hides |
| T10.3 | Web state preserved | T10.1 → browse → T10.2 → T10.1 | Web page still loaded |

### T11 — Settings UI
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T11.1 | Open settings | Tap gear icon | Settings sheet appears with host/port fields |
| T11.2 | Change host | Clear host → type new host | Text field updates |
| T11.3 | Local preset | Tap "Use Local Dev Server" | Host=10.0.0.111, Port=8765 |
| T11.4 | Production preset | Tap "Use Production Server" | Host=relay.ai.qili2.com, Port=443 |
| T11.5 | Reconnect | Change settings → tap Reconnect | Sheet dismisses, reconnects to new server |
| T11.6 | Persistence | Change settings → Reconnect → kill app → relaunch | Settings preserved |
| T11.7 | Done button | Tap Done | Sheet dismisses without reconnecting |

### T12 — Error Handling
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T12.1 | Connection error | Connect to invalid relay | Error banner appears with message + Retry button |
| T12.2 | Retry | T12.1 → tap Retry | Attempts reconnection |
| T12.3 | Relay disconnect mid-chat | Kill relay while chatting | Status dot turns red, connection error shown |
| T12.4 | Input disabled on error | T12.1 → try typing | Input field disabled during error/connecting states |

### T13 — Status Indicator
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T13.1 | Connected state | Normal operation | Green dot in toolbar |
| T13.2 | Disconnected state | Kill relay | Red dot in toolbar |
| T13.3 | Bridge status | With bridge server running | Shows "bridge:connected" text |

### T14 — Scroll & Layout
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T14.1 | Auto-scroll | Receive new message | View auto-scrolls to show latest message |
| T14.2 | Manual scroll | Scroll up to old messages | Can browse history, no jumping |
| T14.3 | Keyboard avoidance | Tap input field | Keyboard appears, chat scrolls up, input stays visible |
| T14.4 | Orientation | Rotate device | Layout adapts (if supported) |

### T15 — MCP / AppAgent (Automated Testing)
| # | Scenario | Steps | Expected |
|---|----------|-------|----------|
| T15.1 | Screenshot | AppAgent: `screenshot` | Returns base64 JPEG of current screen |
| T15.2 | Snapshot elements | AppAgent: `snapshot` | Returns accessibility tree with refs |
| T15.3 | Tap element | AppAgent: `tap` on text field ref | Text field gains focus |
| T15.4 | Type via agent | AppAgent: `type` ref="input" text="test" | "test" appears in input |
| T15.5 | Send via MCP | MCP: `send_message` content="hello" | Message sent in chat |
| T15.6 | Get messages | MCP: `get_messages` | Returns all chat messages as JSON |
| T15.7 | Get status | MCP: `get_status` | Returns connection state, agent state |

---

## Priority Order for Testing

**P0 — Must work (blocking):**
T1.1, T1.2, T2.1, T2.2, T2.3, T4.1, T4.5, T14.3

**P1 — Core features:**
T2.4, T2.5, T3.1–3.5, T4.2–4.4, T4.6, T5.1–5.2,
T7.1–7.2, T7.6, T8.1–8.3, T8.6,
T9.1–9.3, T9.5, T10.1–10.2, T11.1–11.5

**P2 — Important flows:**
T6.1–6.4, T7.3–7.5, T7.7, T8.4–8.5, T8.7,
T9.6–9.9, T9.12, T12.1–12.4, T13.1–13.3, T14.1–14.4, T15.1–15.7

**P3 — Edge cases:**
T1.3–1.4, T2.6, T3.6, T4.7, T7.4, T8.8, T9.10–9.11, T11.6–11.7
