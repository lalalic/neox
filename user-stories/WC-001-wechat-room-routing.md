# WC-001 WeChat Room Project Assistant Routing

## Priority: P1

## Preconditions
1. Channel type set to "wechat" (`channel_switch wechat`)
2. Room bound to test-room-assistant (`wechat_test_setup`)
3. Selected scope is test-room-assistant

## Steps
1. `channel_switch` to "wechat"
2. `wechat_test_setup` with room and direct bindings
3. Open Projects, select test-room-assistant
4. `wechat_simulate_incoming` from room with sender: "What is 25+37?"
5. Wait for agent response (~10s)
6. Verify response in chat with correct source label "WeChat | 三人组 | sender"
7. Verify response sent back to room contact
8. **Negative**: send message from direct contact (文件传输助手) → should NOT appear in chat

## Assertions
- [x] Room message routes to room-bound selected project
- [x] Reply sent to same room
- [x] Source label shows room name (not raw ID like @@xxx)

## Negative Assertion
- [x] Direct contact message ignored when room project selected

## Close Loop
- PASS only if positive reply + negative silence + correct room name display all verified
