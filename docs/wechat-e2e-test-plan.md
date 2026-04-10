# WeChat Bidirectional E2E Test Plan

## Prerequisites
- Phone unlocked, Neox app in foreground
- AppAgent MCP responding on port 9223
- WeChat logged in (channelState == .ready)

## Test 1: Setup Test Bindings

Call `wechat_test_setup` MCP tool:
```json
{
  "tool": "wechat_test_setup",
  "arguments": {
    "roomName": "3人组",
    "directName": "文件传输助手"
  }
}
```

Expected:
- Creates project dirs: `test-room-assistant/`, `test-direct-assistant/`
- Binds "3人组" room → `test-room-assistant`
- Binds "文件传输助手" → `test-direct-assistant`
- Routing activated for both

## Test 2: Room Message → Agent (Incoming)

1. Send a message to "3人组" group from another WeChat account
2. Verify NSLog output:
   - `[WeChatRouter] <sender> (w:50) → project 'test-room-assistant': <message>`
   - `[WeChatRouter] Starting/sending to agent`
3. Wait for agent response
4. Verify response appears in 3人组 with 🤖 prefix

## Test 3: Direct Message → Agent (Incoming)

1. Send a message via computer to "文件传输助手"
2. Verify NSLog:
   - `[WeChatRouter] <sender> (w:50) → project 'test-direct-assistant': <message>`
3. Wait for agent response
4. Verify response appears in 文件传输助手 with 🤖 prefix

## Test 4: Loop Prevention

1. Observe that agent responses in WeChat do NOT trigger another routing cycle
2. wechat-bro.js should suppress AI watermarked messages via `_isSentByUs()`

## Test 5: Session State Handling

1. While agent is working (after Test 2), send another message quickly
2. Verify NSLog shows `Agent busy — steering with new message`
3. If agent asks a question (waitingForQuestions), reply in WeChat
4. Verify NSLog shows `Answering pending question`

## Verification Commands

Check device logs:
```bash
xcrun devicectl device process launch --console --device 00008101-001609640C22001E com.neox.app 2>&1 | grep "\[WeChat"
```

Or via AppAgent:
```json
{
  "tool": "app_agent",
  "arguments": {
    "command": "query",
    "selector": "logs"
  }
}
```

## Known Issues
- AppAgent MCP only works when app is in foreground (screen unlocked)
- File Helper (文件传输助手) is a special contact — sendToContact needs to work with its UserName format
