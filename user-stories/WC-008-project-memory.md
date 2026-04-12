# WC-008 Project Memory Persistence

## Priority: P2

## Description
Verify the agent can write personal preferences to project memory using `memory_write_section`,
then recall them in a subsequent message within the same session.

## Preconditions
1. Channel type set to "wechat"
2. `wechat_test_setup` active (direct contact → test-direct-assistant)
3. Project selected in chat view

## Steps
1. `channel_switch` to "wechat"
2. Select test-direct-assistant project
3. `wechat_simulate_incoming` from="文件传输助手" message="记住我喜欢喝咖啡，不喜欢茶"
4. Wait for agent response (~15s — may call memory_write_section tool)
5. Verify agent confirms it remembered the preference
6. `wechat_simulate_incoming` from="文件传输助手" message="我喜欢什么饮料？"
7. Wait for agent response (~10s)
8. Verify agent correctly recalls "coffee" preference (and that tea is disliked)

## Assertions
- [ ] Agent writes preference to memory (via memory tool)
- [ ] Agent confirms remembering the preference
- [ ] On follow-up question, agent correctly recalls coffee preference
- [ ] Agent mentions tea is disliked (demonstrates nuance retention)
