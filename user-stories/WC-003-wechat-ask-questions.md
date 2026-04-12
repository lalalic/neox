# WC-003 WeChat Ask-Questions Roundtrip

## Priority: P1

## Preconditions
1. Channel type set to "wechat"
2. WeChat binding configured
3. Matching project scope selected

## Steps
1. `channel_switch` to "wechat"
2. Select bound WeChat project
3. `wechat_simulate_incoming` with prompt that triggers ask_questions (e.g. "Help me plan a new feature for my project")
4. Wait for agent to call ask_questions
5. Verify ❓ question appears in chat with WeChat source label
6. `wechat_simulate_incoming` with answer text from same contact
7. Wait for agent to process answer
8. Verify final response posted

## Assertions
- [x] Agent calls ask_questions → forwarded via `onChannelQuestions` callback
- [x] Question mirrored to main chat with correct source label
- [x] Answer routed back triggers agent final response

## Close Loop
- PASS only if question dispatched AND answer processed AND final response visible
