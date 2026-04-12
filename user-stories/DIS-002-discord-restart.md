# DIS-002 Discord Restart Persistence

## Priority: P1

## Preconditions
1. DIS-001 completed successfully
2. App can be restarted via device tooling

## Steps
1. Record current channel bindings
2. Terminate app: `xcrun devicectl device process terminate`
3. Launch app: `xcrun devicectl device process launch`
4. Wait for app ready (~10s)
5. Re-select bound project scope
6. Send Discord message to wired channel
7. Verify reply arrives

## Assertions
- [x] Channel binding persists after app restart
- [x] Reply loop works without rewiring

## Negative Assertion
- [x] With no selected scope after restart, messages ignored

## Close Loop
- PASS only if post-restart reply confirmed AND no-scope silence confirmed
