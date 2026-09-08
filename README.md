# Neox

A headless iPhone app whose only consumer is a **desktop coding agent**. It runs
an MCP (Model Context Protocol) server on the local network so an agent can
search, analyze, and pull photos/videos off the phone over WiFi.

**No chat UI. No channels. One status screen.**

```
┌ iPhone ─────────────────────────────┐      ┌ Desktop agent ────────────┐
│ Neox.app                            │      │ Copilot / Claude / any    │
│  └ MCP server :9223/mcp             │◀────▶│ MCP client                │
│     └ /files/<name>  (Range/206)   │ WiFi │                           │
└─────────────────────────────────────┘      └───────────────────────────┘
```

## Quick start (agent side)

1. Launch **Neox** on the phone (find it via Bonjour `neox._mcp._tcp`, or read
   the endpoint URL from the status screen).
2. Point any MCP client at it — e.g. `.vscode/mcp.json`:

```json
{
  "servers": {
    "neox": { "url": "http://10.0.0.135:9223/mcp" }
  }
}
```

3. On first use the agent should call `media.search`; iOS will prompt for
   Photos permission — tap Allow once on the phone.

## Tools (11)

| tool | purpose | key args |
|---|---|---|
| `media.search` | enumerate library assets | `media_type` (all/image/video), `days`, `after`, `before`, `album`, `favorited`, `limit`, `offset` |
| `media.export` | export originals to `/files/` (videos optionally transcoded) | `ids[]`, `preset` (original/720p/1080p) |
| `media.meta` | full EXIF/TIFF/GPS metadata for one asset | `id` |
| `media.thumbnail` | JPEG preview served at `/files/` | `id`, `max_side` |
| `vision.classify` | on-device scene classification | `id`, `query`, `max_results` |
| `vision.ocr` | text recognition | `id` |
| `vision.detect_people` | faces + bodies with boxes/landmarks | `id` |
| `vision.similarity` | visually similar assets (feature-print scan) | `id`, `limit`, `days` |
| `video.sample_frames` | evenly-spaced JPEG frames | `id`, `count`, `interval_s`, `max_side` |
| `video.transcribe` | on-device speech transcription | `id`, `language` |
| `clear_exports` | free phone space after downloads | — |

Conventions: tool results are compact JSON or `/files/...` URLs — never base64
media. Fetch files with ranged HTTP (`curl -C - "$URL"` resumes automatically).
All analysis (Vision, Speech) runs on-device; nothing leaves the LAN.

## Example session

```bash
PHONE=http://10.0.0.135:9223
call() { curl -s -X POST $PHONE/mcp -H 'Content-Type: application/json' \
         -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",
              \"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }

# discover
curl -s -X POST $PHONE/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | jq

# find recent videos, export one at 720p, pull it
IDS=$(call media.search '{"media_type":"video","days":30,"limit":1}' \
      | jq -r '.result.content[0].text | fromjson | .assets[0].id')
URL=$(call media.export "{\"ids\":[\"$IDS\"],\"preset\":\"720p\"}" \
      | jq -r '.result.content[0].text | fromjson | .exports[0].url')
curl -C - -o clip.mp4 "$PHONE$URL"

# analyze without downloading: classify + transcribe
call vision.classify "{\"id\":\"$IDS\"}" | jq
call video.transcribe "{\"id\":\"$IDS\"}" | jq

# housekeeping
call clear_exports '{}'
```

## Building

Requirements: Xcode 16+ (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen),
an Apple Developer team for device signing. No external SPM dependencies.

```bash
xcodegen generate          # → Neox.xcodeproj
open Neox.xcodeproj        # run on simulator or device
```

See `AGENTS.md` for repo layout and the machine-room notes (remote build,
signing quirks, deployment).

## Scope notes

- **LAN only.** No auth (personal device on home WiFi), no relay, no CDN.
- **Foreground-first.** iOS suspends sockets when backgrounded; the app is
  meant to be used plugged in ("charging dock"). Keep the screen on for
  reliable serving.
- Only the status screen is human-facing; every feature is agent-first.
