# DIS-001 Discord First-Time Setup and Reply

## Priority: P1

## Preconditions
1. Discord bot online in relay (`GET /api/discord/status`)
2. Project exists with Discord channel binding
3. Channel type is "discord" (`channel_switch discord`)

## Steps
1. `channel_switch` to "discord"
2. Open Projects, select test-room-assistant (bound to #pathfinder)
3. Send message via relay: `POST /api/discord/test-message` to pathfinder channel with "What is 2+2?"
4. Wait for agent response in Discord channel
5. Verify response appears in app chat (mirrored)
6. Select test-direct-assistant (bound to #general), send message to pathfinder → should be ignored

## Assertions
- [x] Inbound Discord message reaches app routing path
- [x] Agent reply posted back to same Discord channel
- [x] Reply content is contextually correct

## Negative Assertion
- [x] Message to channel bound to non-selected project → no reply

## Close Loop
- PASS only if positive reply verified AND negative silence verified
