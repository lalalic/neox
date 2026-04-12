# WC-006 Link Share → Agent Summarizes

## Priority: P2

## Description
Send a simulated link/app message (msgType 49, appType 5) via WeChat. Verify the agent receives
the link details (title, description, URL) and responds with a meaningful summary.

## Preconditions
1. Channel type set to "wechat"
2. `wechat_test_setup` active (direct contact → test-direct-assistant)
3. Project selected in chat view

## Steps
1. `channel_switch` to "wechat"
2. Select test-direct-assistant project
3. `wechat_simulate_incoming` from="文件传输助手" message="" msgType=49 appType=5 appTitle="Apple announces WWDC 2026" appDesc="Apple has announced dates for its annual Worldwide Developers Conference." appUrl="https://developer.apple.com/wwdc26/"
4. Wait for agent response (~10s)
5. Verify chat shows formatted link info (title, description, URL)
6. Verify agent response references the link content meaningfully
7. Verify response has "WeChat | 文件传输助手" label

## Assertions
- [ ] Link message formatted as `[Title: ...] [Description: ...] [URL: ...]`
- [ ] Agent response references WWDC / Apple / developers conference
- [ ] Chat shows "WeChat | 文件传输助手" label
