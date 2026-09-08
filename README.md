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

## Siri / Shortcuts → agent chat

The app exposes two App Intents:

**Run Agent Task** does no reasoning: it makes sure the MCP server is up, then
produces a message that contains just the user instruction and this phone's
MCP URL:

```
Create a vlog from yesterday's photos and videos

iPhone media MCP server: http://10.0.0.135:9223/mcp
LAN only, no auth. Discover tools with tools/list first; inspect metadata and
thumbnails before exporting; stream originals from /files/ over HTTP — never
inline media in the chat.
```

Delivery is owned by Codex Remote / Shortcuts:

- The intent **foregrounds the app before running** — Wi-Fi automations fire in
  the background, where iOS can suspend the app and drop the MCP listener;
  foregrounding makes the server reliably reachable (the status screen is also
  visible confirmation that the automation fired).
- **Photos preflight**: if Photos permission hasn't been granted, the intent
  requests it during the run, so a later unattended `media.search` doesn't hit
  a permission wall. The result dialog reports the permission state.

- Siri phrases: *"Create a vlog with Neox"*, *"Make a vlog with Neox"*,
  *"Run my agent with Neox"* — plus *"Analyze my media with Neox"* which runs
  the vision index batch (see below). Free-form instructions
  are configured by editing the Run Agent Task step in the Shortcuts editor
  (App Intents only allows entity-typed phrase placeholders, so the instruction
  isn't Siri-capturable).
- **Analyze Media** (phrases: *"Analyze my media with Neox"*, *"Index my photos
  with Neox"*) batch-runs the vision index (default: last 7 days) and reports
  the summary; `days` / `re-analyze` parameters are editable in the Shortcuts
  editor.
- The intent's **output value** is the full message, so a Shortcut can chain it
  straight into the Codex chat ("Run intent → send to agent").
- The message is also **copied to the clipboard** as a manual fallback.
- The status screen previews the exact message that would be sent.

Wi-Fi automation lives entirely in Shortcuts (Automation: *When connected to
home Wi-Fi → Run "Run Agent Task" → send output to Codex*) — the app never
detects the network transition.

## Tools (14)

| tool | purpose | key args |
|---|---|---|
| `media.search` | enumerate library assets; vision-index content filters | `media_type` (all/image/video), `days`, `after`, `before`, `album`, `favorited`, `has_label`, `has_text`, `with_people`, `limit`, `offset` |
| `media.export` | export originals to `/files/` (videos optionally transcoded) | `ids[]`, `preset` (original/720p/1080p) |
| `media.meta` | full EXIF/TIFF/GPS metadata for one asset | `id` |
| `media.thumbnail` | JPEG preview served at `/files/` | `id`, `max_side` |
| `vision.classify` | on-device scene classification | `id`, `query`, `max_results` |
| `vision.ocr` | text recognition | `id` |
| `vision.detect_people` | faces + bodies with boxes/landmarks | `id` |
| `vision.similarity` | visually similar assets (feature-print scan) | `id`, `limit`, `days` |
| `vision.index` | batch-analyze library (labels/OCR/people) into the persistent index | `days` (default 7), `redo`, `limit` (default 200) |
| `video.sample_frames` | evenly-spaced JPEG frames | `id`, `count`, `interval_s`, `max_side` |
| `video.transcribe` | on-device speech transcription | `id`, `language` |
| `clear_exports` | free phone space after downloads | — |
| `app_agent` | remote UI automation of this app (self-testing) | `command`: snapshot/tap/tap_xy/type/swipe/long_press/find/scroll_to/pick/screenshot |
| `demo` | visual demo overlays (spotlight, caption, TTS…) | `command`: step/spotlight/annotate/caption/say/cursor/highlight/clear/pause/resume/wait/start_recording/stop_recording |

## Vision index — persistent media knowledge

`vision.index` (MCP tool) and **Analyze Media** (Siri: *"analyze my media with
Neox"*) batch-run on-device Vision over the library and persist per-asset
results (top labels, OCR text, face/people counts) in
`Application Support/Neox/vision-index.json`, keyed by asset id. Once indexed:

- `media.search` gains `has_label` / `has_text` / `with_people` filters, and
  every row carries a compact `vision` summary (top 3 labels, faces, text flag)
- `media.meta` includes the full `analysis` section
- incremental by default: already-indexed assets are skipped unless `redo`

So `media.search {"has_label":"beach"}` or `{"has_text":"receipt"}` finds media
by *content* without any downloads or re-analysis.

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

# content search over the vision index (no downloads, no re-analysis)
call media.search '{"days":30,"has_label":"beach","limit":5}' | jq
call media.search '{"days":30,"has_text":"receipt","limit":5}' | jq

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
