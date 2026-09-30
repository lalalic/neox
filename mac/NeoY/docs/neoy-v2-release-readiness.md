# NeoY v2 release-readiness evidence

This closeout was run against PR head `be7c2c1472a2405d83073402c832507dc5d69c4c`
on 2026-09-30. The evidence below is from the current checkout and the signed
installed app, not a prior run.

## Fresh validation

- `xcodegen generate && xcodebuild -project NeoY.xcodeproj -scheme NeoY -configuration Debug test CODE_SIGNING_ALLOWED=NO` passed: **16/16 tests**.
- `/Applications/NeoY.app` is signed as `com.neox.neoy` with the local Apple Development identity and reports runtime version `2.0.0`.
- Installed MCP health and `initialize` succeeded on `http://127.0.0.1:9224/mcp`; the server reports MCP protocol `2025-03-26` and version `2.0.0`.
- Installed `neoy.setup` status reports control-plane schema `2`, ready state, active MCP and handoff endpoints, and `launch-agent-keepalive` startup mode.
- Runtime help exposes one setup/control entry with status, versioned config, diagnostics, permissions, supervised startup, MCP federation, and event-policy commands.
- A disposable `/usr/bin/true` startup service was added, listed with exit code `0`, mutated to `on-failure`, observed in persisted `config show`, and removed. Final configuration is clean.
- Permissions status correctly reports Accessibility and Screen Recording authorized, camera/microphone/notifications not determined, and Local Network as a runtime probe. Guidance states where human approval is required.
- The `com.neox.neoy.keepalive` launchd job was running. After terminating the installed process, launchd restarted it and MCP health recovered on port 9224.
- Event policy reports `blocked`, `failure`, and `completed` enabled. The installed status reports NeoX pairing is not selected, so no physical-device notification was claimed.

## Acceptance status

The menu-bar/headless runtime, stable identity, typed schema-v2 control plane,
permission guidance, supervised startup, MCP serving/federation seams, compact
setup contract, and NeoX event policy are implemented and freshly validated.
Browser/ChatGPT-specific MacBridge glue remains outside NeoY Core as recorded in
the migration matrix.

The remaining release prerequisite is external: visibly receiving a NeoX event
on a paired physical iPhone requires a selected paired device and iOS
notification authorization. The code path and policy are present, but this
environment does not provide that authorized pairing; release evidence must
keep this boundary explicit rather than treating the local event-policy check
as proof of delivery.

