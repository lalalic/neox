# Troubleshooting

- Bonjour/status fallback: if discovery is empty, read the endpoint shown in Neox's status screen and verify the phone and desktop share the same LAN.
- iOS foreground suspension: bring Neox to the foreground before long-running media work or an unattended handoff; background suspension can stop the listener.
- Permissions: grant Local Network and Photos access in iOS Settings. A denied Photos permission makes search/export fail even when MCP is reachable.
- Long operations: use a generous client timeout, inspect before transfer, and use ranged/resumable downloads. Do not retry blindly while an export is still running.
- Bridge fallback: if Neoy is unavailable, use the returned intent value or clipboard. Media sessions continue without Neoy.
- Multiple watchers: queue consumers are reference desktop behavior; multiple watchers may race and delivery is at-most-once. Run one consumer when exact delivery matters.
- LAN-only safety: never publish the phone endpoint or bridge through a public IP, port forward, relay, or unauthenticated internet-facing proxy.
