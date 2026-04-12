# Trace 2 — 2026-07-13 (Clean Run)

## Summary
- Stories tested: 8/8
- **PASS: 8**, FAIL: 0, BLOCKED: 0
- Bugs found: 1 (fixed during trace) + 1 finding (non-blocking)

---

## CH-001 Exclusive Channel Mode Toggle — PASS ✅

### Positive: WeChat message processed
- `channel_switch wechat`, selected test-direct-assistant
- Sent "CH-001 positive: what is 8+3?" from 文件传输助手
- Response: "8 + 3 equals 11" ✅

### Negative: Discord message blocked
- Relay sent "CH-001 NEGATIVE: this MUST be blocked!" to Discord #general
- Channel not registered (expected in wechat mode) → NOT in chat ✅

---

## WC-001 WeChat Room Routing — PASS ✅

### Positive: Room message routed correctly
- Selected test-room-assistant (bound to 三人组)
- Sent "WC-001: what is 15 times 4?" from 三人组/Bob
- Response: "15 times 4 is 60." with "WeChat | 三人組" label ✅

### Negative: Unbound contact ignored
- Sent "WC-001 NEGATIVE from filehelper to room project" from 文件传输助手
- NOT in test-room-assistant view ✅

---

## WC-002 WeChat Direct Message Routing — PASS ✅

### Positive: Direct message routed correctly
- Selected test-direct-assistant (bound to 文件传输助手)
- Sent "WC-002: what is 99 divided by 3?" from 文件传输助手
- Response: "99 divided by 3 equals 33" ✅

### Negative: Room message not routed to direct project
- Sent "WC-002 NEGATIVE: room msg to direct project" from 三人組/Alice
- NOT in test-direct-assistant view ✅

---

## WC-003 WeChat Ask-Questions Roundtrip — PASS ✅

### Questions forwarded
- Sent "WC-003: I want to organize my home office..." from 文件传输助手
- Agent called ask_questions → 3 questions forwarded via onChannelQuestions ✅
  1. "What are the dimensions of your home office?"
  2. "What furniture do you currently have?"
  3. "Any specific preferences (standing desk, etc.)?"

### Answer roundtrip
- Sent answer: "Room is 12x10 feet. Desk, chair, bookshelf. Standing desk + natural light."
- Agent processed: "Thanks for the details! For a 12x10 ft room..." ✅
- Follow-up questions generated ✅
- Response sent to filehelper OK (confirmed in router status) ✅

### Finding (non-blocking)
- Initial agent response held by guardrail: "Auto-detected sensitive content in response" — false positive on "redesign" word. Not blocking the ask_questions flow.

---

## WC-004 WeChat Assistant Auto-Reply — PASS ✅

### Guardrail test
- Sent "你能帮我查一下我的银行余额吗？" from 文件传输助手
- Guardrail fired: "Money, payments, transfers, bank accounts" ✅

### Auto-start verified
- Badge shows "2" (watcher count) ✅

---

## DIS-001 Discord Setup & Reply — PASS ✅

### BUG FIXED: Discord rewire on channel_switch
- After app started with channelType=wechat, `channel_switch discord` did NOT re-register Discord channels
- **Root cause**: `wireDiscord(to:)` was only called at init time; if channelType was "wechat" at init, Discord never wired
- **Fix**: Added `rewireDiscordIfNeeded()` method to AgentCoordinator, called from `channel_switch` when switching to discord
- After fix: `channel_switch discord` → both #general and #pathfinder registered ✅

### Positive: Discord message processed
- Selected test-room-assistant (bound to #pathfinder)
- Relay sent "DIS-001: what is 7+9?" to #pathfinder
- Response: "7 + 9 equals 16" with "Discord | #pathfinder" label ✅

### Negative: Unbound channel ignored
- Sent "DIS-001 NEGATIVE from general to room project" to #general
- NOT in test-room-assistant view ✅

---

## DIS-002 Discord Restart Persistence — PASS ✅

### Persistence after restart
- Terminated app (PID 13412) and relaunched
- Both channels auto-registered after restart ✅
  - #general → test-direct-assistant
  - #pathfinder → test-room-assistant
- Project list shows correct bindings (#general, #pathfinder) ✅

### Post-restart message delivery
- Selected test-room-assistant
- Sent "DIS-002 retry: what is 5*5 after restart?" to #pathfinder
- Response: "5*5 equals 25" ✅

### Negative: No-scope silence
- Selected "All Messages" (no project scope)
- Sent "DIS-002 NEGATIVE: no scope selected" to #pathfinder
- NOT in current view ✅

---

## DIS-003 Discord Ask-Questions Roundtrip — PASS ✅

### Questions forwarded to Discord
- Selected test-direct-assistant (→ #general)
- Relay sent "DIS-003: I want to start a vegetable garden..." to #general
- Agent response: "That's a great idea! To help you plan..." ✅
- 4 questions forwarded to Discord #general with ❓ prefix ✅
  1. "How much space do you have?"
  2. "How many hours of sunlight?"
  3. "Specific vegetables to grow?"
  4. "First time gardening or experienced?"
- Verified in Discord browser: messages from "Neo App" visible ✅

### Answer roundtrip
- Relay sent: "About 10x15 feet. Gets 6 hours of sun. Tomatoes, peppers, herbs. First time."
- Agent processed: "Thanks for the details! With a 10x15 ft space..." ✅
- Follow-up questions forwarded to Discord ✅
- Full roundtrip confirmed working ✅

---

## Bugs Fixed During Trace

### BUG-1: Discord channel_switch doesn't rewire after app init with channelType=wechat
- **Files changed**: AgentCoordinator.swift (added `rewireDiscordIfNeeded()`), AppAgentSetup.swift (call rewire on discord switch)
- **Status**: Fixed and verified

## Findings (Non-blocking)

### FINDING-1: Guardrail false positive on "redesign" 
- Initial response for WC-003 home office redesign was held by guardrail as "sensitive content"
- The word "redesign" may be matching a sensitive pattern. Should investigate guardrail rules.
- Non-blocking: ask_questions flow still works correctly despite the hold

## Conclusion
**All 8 stories PASS.** One code bug found and fixed (Discord rewire). One non-blocking finding noted.

