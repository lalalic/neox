# CH-001 Exclusive Channel Mode Toggle

## Priority: P1

## Preconditions
1. App installed and launched
2. Both channel configs available (Discord + WeChat)

## Steps
1. `channel_switch` to "wechat"
2. Verify `channel_switch` reports `channelType: wechat`
3. `wechat_simulate_incoming` from bound contact → should route
4. `channel_switch` to "discord"
5. Verify `channel_switch` reports `channelType: discord`
6. `wechat_simulate_incoming` from same contact → should be BLOCKED
7. Send Discord message via relay → should route

## Assertions
- [x] Exactly one channel type active at any time
- [x] Inactive channel messages are silently dropped (no routing, no response)
- [x] Active channel messages route and get responses

## Close Loop
- PASS only if both positive AND negative assertions verified in same run
- Must see "ignoring WeChat message" in logs when Discord active
