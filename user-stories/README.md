# Neox E2E User Stories

## Test Infrastructure
- **iPhone 12 mini**: `00008101-001609640C22001E`
- **AppAgent MCP**: `http://10.0.0.141:9223/mcp`
- **Relay API**: `localhost:8766`
- **Discord**: Neo guild `1484163441966059652`, #general `1484163442406326384`, #pathfinder (via lalalic guild)
- **agent-browser**: Chrome remote debugging port 9222

## Story Index

| ID | File | Channel | Description | Close Loop Requires |
|---|---|---|---|---|
| CH-001 | [CH-001](CH-001-exclusive-channel-mode.md) | Both | Exclusive channel mode toggle | Positive route + negative block |
| DIS-001 | [DIS-001](DIS-001-discord-setup-reply.md) | Discord | First-time setup and reply | Reply + wrong-project silence |
| DIS-002 | [DIS-002](DIS-002-discord-restart.md) | Discord | Restart persistence | Post-restart reply + no-scope silence |
| DIS-003 | [DIS-003](DIS-003-discord-ask-questions.md) | Discord | Ask-questions roundtrip | Prompt → question → answer → response |
| WC-001 | [WC-001](WC-001-wechat-room-routing.md) | WeChat | Room project assistant routing | Reply + wrong-project silence + room name |
| WC-002 | [WC-002](WC-002-wechat-direct-routing.md) | WeChat | Direct assistant routing | Reply + wrong-project silence + name |
| WC-003 | [WC-003](WC-003-wechat-ask-questions.md) | WeChat | Ask-questions roundtrip | Question → answer → response |
| WC-004 | [WC-004](WC-004-wechat-assistant-auto-reply.md) | WeChat | Background auto-reply assistant | Auto-start + natural reply + guardrail |

## Run Order
1. CH-001 (channel exclusivity — foundation for all others)
2. WC-001 (room routing)
3. WC-002 (direct routing)
4. WC-003 (ask-questions)
5. WC-004 (assistant auto-reply + guardrails)
6. DIS-001 (Discord setup)
7. DIS-002 (restart)
8. DIS-003 (Discord ask-questions)

## Close Loop Rules
- Every story must verify BOTH positive and negative assertions
- A story is PASS only when ALL assertions checked in the SAME run
- Log exact commands and responses in trace file
- Any unverified assertion = FAIL, not SKIP

## Trace Files
Each test round produces a trace file: `traces/trace-N.md`

Trace format:
```
# Trace N — YYYY-MM-DD HH:MM

## Summary
- Stories tested: X/8
- PASS: N, FAIL: N, BLOCKED: N
- Bugs found: [list]

## CH-001
- Step 1: [command] → [result]
- Step 2: ...
- Positive: ✅/❌ [evidence]
- Negative: ✅/❌ [evidence]
- Result: PASS/FAIL/BLOCKED

## [repeat for each story]

## Bugs Found
- BUG-N: [description] → [fix status]
```

## Goal
Run all stories repeatedly until one complete trace has ZERO bugs (all PASS, no FAIL/BLOCKED).
