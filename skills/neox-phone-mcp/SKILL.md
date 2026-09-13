---
name: neox-phone-mcp
description: Use when an iPhone running Neox should provide local MCP access to photos/videos or initiate a phone-to-desktop-agent handoff.
---

# Neox phone capabilities

Use Neox as a local, LAN-only MCP server for the phone's Photos library. Phone media access and phone-initiated handoff are related capabilities, but independent: media work does not require Neoy; Neoy is only needed when the phone must start a desktop-agent turn.

## Choose a connection

1. Discover the Neox endpoint from Bonjour (`neox._mcp._tcp`) or the phone status screen.
2. Prefer a harness-native MCP client when it can attach to the endpoint.
3. Call `tools/list` on the live endpoint before using tools. The live schema and source implementation are authoritative; do not assume this document contains every tool or argument.
4. Use raw curl/JSON-RPC only as a fallback or for diagnostics; see [references/mcp-tools.md](references/mcp-tools.md).

Neox is intentionally LAN-only and unauthenticated. Do not expose its endpoint, `/files/`, or a Neoy bridge to the public internet; reject relay/port-forwarding architectures.

## Media workflow

Follow this order:

`search → index if needed → inspect → export → ranged download → clear`

- Search first. For receipts, captions, labels, or other content, use indexed content filters before exporting anything.
- If content coverage is missing, call `vision.index`, then retry `media.search`.
- Inspect `media.meta`, `media.thumbnail`, OCR, or sampled frames before transferring large media.
- For huge video, sample frames (and transcribe when useful) before export. For a draft vlog, prefer a reduced preset such as 720p unless the requested quality requires the original.
- Export only selected IDs, download from the returned `/files/` URL with range/resume support, and call `media.clear` after successful downloads.

See [references/mcp-tools.md](references/mcp-tools.md) for tool arguments and the raw protocol fallback.

## Phone-initiated handoff

Neoy is optional. Use it only when a phone intent must deliver a complete instruction to a desktop agent. The phone discovers `_neoy._tcp` and sends `POST /agent` with `Content-Type: text/plain`; HTTP 200 means delivered. If no bridge is found, use the intent output or clipboard and paste the handoff into the agent session. The stable phone-facing contract and desktop queue details are in [references/bridge-protocol.md](references/bridge-protocol.md).

## Recovery and safety

For an unreachable endpoint, diagnose foreground state, Photos/Local Network permissions, Bonjour discovery, and LAN connectivity before retrying. Keep the app foregrounded for long-running operations because iOS may suspend background sockets. Use [references/troubleshooting.md](references/troubleshooting.md) for recovery guidance.
