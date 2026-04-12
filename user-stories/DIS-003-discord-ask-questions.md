# DIS-003 Discord Ask-Questions Roundtrip

## Priority: P1

## Preconditions
1. DIS-001 completed
2. Bound project selected
3. agent-browser connected to Discord (port 9222)

## Steps
1. `channel_switch` to "discord"
2. Select bound Discord project
3. Send prompt that triggers ask_questions via relay (e.g. "Help me organize my bookshelf")
4. Wait for ❓ Question to appear in Discord channel
5. Answer from browser Discord (type answer and send)
6. Wait for agent to process answer
7. Verify final response posted to same channel

## Assertions
- [x] Agent calls ask_questions → question forwarded to Discord channel
- [x] Browser answer routed back through relay to project session
- [x] Agent processes answer and produces final response
- [x] Final response posted to same Discord channel

## Close Loop
- PASS only if full roundtrip: prompt → question → answer → response all verified
- Must use browser Discord for the answer (not relay API)
