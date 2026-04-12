# WC-002 WeChat Direct Assistant Routing

## Priority: P1

## Preconditions
1. Channel type set to "wechat"
2. Direct contact bound to test-direct-assistant
3. Selected scope is test-direct-assistant

## Steps
1. `channel_switch` to "wechat"
2. `wechat_test_setup` (binds 文件传输助手 → test-direct-assistant)
3. Open Projects, select test-direct-assistant
4. `wechat_simulate_incoming` from="文件传输助手" message="What is 7 times 8?"
5. Wait for agent response
6. Verify response in chat with source label "WeChat | 文件传输助手"
7. **Negative**: `wechat_simulate_incoming` from room → should NOT appear in chat

## Assertions
- [x] Direct message routes to direct-bound selected project
- [x] Reply sent to same contact
- [x] Source label shows contact name (not raw userName)

## Negative Assertion
- [x] Room message ignored when direct project selected

## Close Loop
- PASS only if positive reply + negative silence + correct name display all verified
