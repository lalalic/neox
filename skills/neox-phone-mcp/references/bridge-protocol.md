# Neoy bridge protocol

## Stable phone-facing contract

- Desktop bridge advertises Bonjour service `_neoy._tcp`.
- The phone sends `POST /agent`.
- Request `Content-Type` is `text/plain`.
- The body is the complete handoff message, including the user's instruction and phone MCP URL.
- HTTP 200 means the message was delivered.
- TXT records may include `host=`, `port=`, and `ip=`. When present, the phone prefers `ip=` over hostname resolution.

Neoy is only for phone-initiated handoff. A desktop agent connecting to Neox for media does not need Neoy.

## Reference desktop implementation

`/agent/next`, `/agent/peek`, FIFO files, long-polling, and watcher behavior describe the current desktop queue implementation, not requirements that phone clients must implement. The standalone reference bridge is [../scripts/neoy-bridge.py](../scripts/neoy-bridge.py); it accepts phone POSTs and exposes a local queue for a desktop consumer.

When no bridge is discovered, preserve the complete handoff through the intent output or clipboard and paste it into the desktop agent.
