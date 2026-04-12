# WC-005 Image Message → Agent Describes

## Priority: P2

## Description
Send a simulated image message (msgType 3) via WeChat. Verify the image is saved to the project media directory
and the agent uses the `view` tool to describe the image content.

## Preconditions
1. Channel type set to "wechat"
2. `wechat_test_setup` active (direct contact → test-direct-assistant)
3. Project selected in chat view

## Steps
1. `channel_switch` to "wechat"
2. Select test-direct-assistant project
3. Prepare a small test image as base64 (e.g., a simple colored rectangle)
4. `wechat_simulate_incoming` from="文件传输助手" message="" msgType=3 imageBase64="<base64>"
5. Wait for agent response (~15s — includes image processing)
6. Verify chat shows `[Image received — use view tool...]` source message
7. Verify agent response describes the image content
8. Verify image file exists in project media directory

## Assertions
- [ ] Image saved to `test-direct-assistant/media/jpg-*.jpg`
- [ ] Agent calls `view` tool on the saved image
- [ ] Agent response includes description of image content
- [ ] Chat shows "WeChat | 文件传输助手" label
