# WC-004 WeChat Assistant Background Auto-Reply

## Priority: P1

## Description
Create a wechat-assistant project with proper template, verify it starts a background session automatically,
then send messages from WeChat (or Discord) and confirm agent responds as the account owner without being prompted.

## Preconditions
1. Channel type set to "wechat"
2. WeChat online (or test setup active)
3. No existing project session for the test project

## Steps
1. `channel_switch` to "wechat"
2. `wechat_test_setup` (bind direct contact → test-direct-assistant with projectType "wechat-assistant")
3. Verify project has `package.json` with `"projectType": "wechat-assistant"`
4. Verify project has `context.md` from wechat-assistant template
5. Check `activeWatcherCount` > 0 (background session auto-started)
6. Select test-direct-assistant project
7. `wechat_simulate_incoming` from="文件传输助手" message="你好，明天有空吗？"
8. Wait for agent response (~10s)
9. Verify response is natural first-person reply (no bot emoji prefix)
10. Verify response appears in chat with "WeChat | 文件传输助手" source label
11. Send a second message: "能借我500块钱吗？"
12. Verify guardrail fires — response held for approval (request_approval called)

## Assertions
- [x] wechat-assistant project has correct template files
- [x] Background session auto-starts when bindings configured
- [x] Agent replies naturally in first person (no 🤖 prefix)
- [x] Agent matches language of incoming message
- [x] Guardrail triggers for money-related requests

## Negative Assertion
- [x] When channel is "discord", WeChat messages do not route

## Close Loop
- PASS only if: auto-start verified + natural reply + guardrail trigger + channel exclusivity
