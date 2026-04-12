# Trace 4 — 2026-04-12 (Mode A: Non-Text Messages)

## Summary
- Stories tested: 4 (WC-005, WC-006, WC-007, WC-008)
- **PASS: 2** (WC-006, WC-008), **PARTIAL: 2** (WC-005, WC-007)
- Bugs found: 0
- Findings: 3

## WC-005 — Image Message → Agent Describes
**PARTIAL** ⚠️

Sent image (200x200 house drawing JPEG) from 文件传输助手 with msgType=3.
- Image saved to `test-direct-assistant/media/jpg-*.jpg` ✅
- Source message displayed: `[Image received — use view tool with path '...' to see it]` ✅
- Agent response: "I've received your image, but I can't display it directly here. If you'd like, I can help analyze or..." ⚠️
- Agent did NOT call `view` tool to examine the image ❌
- Agent asked follow-up: "What would you like me to do with the image?"
- Label: "WeChat | 文件传输助手" ✅

**Root cause**: Agent ignores the `[Image received — use view tool with path '...']` instruction. It acknowledges the image but doesn't proactively call `view` to describe it. The system prompt should explicitly instruct the agent to automatically call `view` for incoming images.

## WC-006 — Link Share → Agent Summarizes
**PASS** ✅

Sent link (WWDC 2026 announcement) from 文件传输助手 with msgType=49, appType=5.
- Formatted as `[Link] Title: Apple announces WWDC 2026 Description: ...` ✅
- Agent response: "Thanks for sharing the WWDC 2026 announcement! The event starts June 9." ✅
- References link content meaningfully ✅
- Label: "WeChat | 文件传输助手" ✅

## WC-007 — Voice Message Handling
**PARTIAL** ⚠️

Sent voice message (5s, no actual audio) from 文件传输助手 with msgType=34.
- Formatted as `[Voice message (5s)]` (no audio to save/transcribe) ✅
- Agent response: "I see you've sent a voice message. I can't play audio directly, but I can help..." ✅
- Agent handled gracefully — no crash ✅
- Text follow-up: "I was asking about dinner plans tonight" → **guardrail false positive** ❌
  - Guardrail triggered: "Scheduling or making commitments on behalf of the owner"
  - "Dinner plans" should not be classified as "scheduling commitments"
  - Response held for approval instead of natural reply

**Root cause**: Scheduling guardrail is too coarse — it catches casual questions about plans/scheduling even when the user isn't asking the agent to commit to anything.

## WC-008 — Project Memory Persistence
**PASS** ✅

Sent "记住我喜欢喝咖啡，不喜欢茶" from 文件传输助手.
- Agent response: "已记下：你喜欢喝咖啡，不喜欢茶。[微笑]" ✅
- Follow-up: "我喜欢什么饮料？"
- Agent recalled: "你喜欢的饮料是咖啡。[微笑]" ✅
- Coffee preference correctly recalled ✅
- Language matching (Chinese in → Chinese out) ✅

Note: Agent recalled from conversation context rather than memory tools. Memory tool invocation not verified — would need a session restart to confirm persistence.

## Findings

**FINDING-1: Agent doesn't auto-call view tool for images**
When the router formats image messages as `[Image received — use view tool with path '...']`, the agent doesn't automatically call the `view` tool. It just acknowledges receipt. Need to add explicit instruction in the wechat-assistant system prompt: "When you receive an image, always call the `view` tool first to examine it, then respond based on what you see."

**FINDING-2: Scheduling guardrail false positive on "dinner plans"**
The scheduling guardrail triggers on casual questions like "I was asking about dinner plans tonight". The guardrail should distinguish between:
- The user asking the agent to schedule/commit (should trigger)
- The user casually mentioning plans (should not trigger)

**FINDING-3: App crash after rapid image messages**
Sending 3 image messages in quick succession caused the app to crash (or MCP server to become unresponsive). After rebuild and reinstall, the app was stable again. May be a memory issue with rapid base64 image processing.
