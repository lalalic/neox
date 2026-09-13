# Neox MCP tools and raw fallback

## Live discovery

The phone exposes JSON-RPC 2.0 at `POST /mcp`. Always issue `tools/list` first; implementations and device capabilities can change the available schema. Treat source code and the live response as authoritative when this reference differs.

With a native MCP harness, configure the server URL as the discovered phone endpoint plus `/mcp`, then let the harness perform initialization and tool calls. Do not replace a native client with handwritten HTTP when native attachment works.

## Capability map

- `media.search`: enumerate recent assets; use date/media/album filters and indexed `has_label`, `has_text`, or `with_people` filters.
- `vision.index`: build or refresh the on-device label/OCR/people index when search coverage is missing.
- `media.meta`, `media.thumbnail`, `vision.classify`, `vision.ocr`, `vision.detect_people`: inspect or analyze selected assets.
- `video.sample_frames`, `video.transcribe`: inspect large video before transfer.
- `media.export`: write selected originals or reduced video presets (`720p`, `1080p`) into the phone export directory.
- `media.clear`: remove exported files after they have been downloaded.
- `agent.handoff`: optional phone-to-bridge self-test; it is not needed for ordinary media access.

Arguments must come from the current `tools/list` response. Common examples are `media.search` with `media_type`, `days`/`after`/`before`, `limit`, `offset`, and content filters; `media.export` with `ids` and `preset`; and inspection tools with an asset `id`.

## Raw HTTP/JSON-RPC fallback

```sh
PHONE='http://<phone-ip>:9223'
curl --max-time 5 -s -X POST "$PHONE/mcp" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

For a call, use the exact live tool name and arguments:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"media.search","arguments":{"media_type":"image","days":7,"limit":10}}}
```

Export results contain `/files/<name>` URLs. Download with HTTP range/resume support and never inline media as base64 in a chat. Keep the endpoint private to the trusted LAN.
