# WC-007 Voice Message Handling

## Priority: P2

## Description
Send a simulated voice message (msgType 34) via WeChat. Verify the voice file is saved and the agent
handles it gracefully (either transcribes or acknowledges). Then send a text follow-up to verify
the conversation continues naturally.

## Preconditions
1. Channel type set to "wechat"
2. `wechat_test_setup` active (direct contact → test-direct-assistant)
3. Project selected in chat view

## Steps
1. `channel_switch` to "wechat"
2. Select test-direct-assistant project
3. `wechat_simulate_incoming` from="文件传输助手" message="" msgType=34 voiceLength=5
4. Wait for agent response (~10s)
5. Verify chat shows voice message indicator (duration)
6. Verify agent acknowledges voice message (cannot transcribe without real audio, or attempts transcription)
7. Send text follow-up: `wechat_simulate_incoming` from="文件传输助手" message="I was asking about dinner plans tonight"
8. Wait for agent response (~10s)
9. Verify agent responds naturally to the text follow-up about dinner

## Assertions
- [ ] Voice message acknowledged with duration info
- [ ] Agent handles gracefully (no crash, meaningful response)
- [ ] Text follow-up receives natural conversational response
- [ ] Both messages show "WeChat | 文件传输助手" label
