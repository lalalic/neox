---
name: neox-phone-mcp
description: >-
  Use an iPhone as a local MCP media server via the Neox app: search the
  phone's photo/video library by content (vision index), analyze on-device
  (classify/OCR/people/transcribe), and pull originals over WiFi with ranged
  HTTP. Use when a task needs the user's phone media: "find photos of X",
  "pull recent videos off my phone", "build a vlog from my camera roll",
  "OCR my screenshots", or any macOS agent flow that mentions Neox.
---

# neox-phone-mcp — Drive an iPhone's media library from a desktop agent

The **Neox** iOS app runs an MCP server on the phone's LAN IP (port 9223),
exposing its photo/video library as tools, plus a range-streaming `/files/`
endpoint for originals. Every tool result is compact JSON or a `/files/...`
URL — **never base64 media**. All Vision/Speech analysis runs on-device.

```
┌ iPhone ─────────────────────────────┐      ┌ Desktop agent ────────────┐
│ Neox.app                            │      │ This agent                │
│  └ MCP server :9223/mcp             │◀────▶│ (you) via curl            │
│     └ /files/<name>  (Range/206)   │ WiFi │                           │
└─────────────────────────────────────┘      └───────────────────────────┘
```

## 1. Find the phone

Try in order:

1. **Known endpoint** — `http://10.0.0.135:9223/mcp` (iPhone 17 on the home LAN)
2. **ARP scan** — probe port 9223 on hosts whose ARP entry looks like an iPhone:
   ```bash
   arp -a | awk '/iphone/{print $2}' | tr -d '()'   # candidate IPs
   curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST http://<ip>:9223/mcp -d '{}'
   ```
   A `200` means Neox is there. (ARP labels lie — DHCP moves IPs between
   devices; always confirm by probing, not by name.)
3. **Ask the user** to open Neox and read the endpoint from the status screen
   (green dot = server running).

No `200` anywhere? The phone is likely locked-with-app-closed, or Local Network
permission was just granted without an app restart. Ask the user to open Neox
on the phone (screen on), then re-probe.

## 2. Call tools (raw JSON-RPC over HTTP)

```bash
PHONE=http://10.0.0.135:9223
call() { curl -s -m 120 -X POST $PHONE/mcp -H 'Content-Type: application/json' \
         -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",
              \"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
```

Discover the live tool list first (`tools/list`), then:

| tool | use for | key args |
|---|---|---|
| `media.search` | find assets — incl. **content search** | `media_type`, `days`/`after`/`before`, `album`, `favorited`, `has_label`, `has_text`, `with_people`, `limit`, `offset` |
| `media.meta` | full EXIF/GPS + vision analysis for one asset | `id` |
| `media.thumbnail` | JPEG preview at `/files/` (inspect cheaply) | `id`, `max_side` |
| `vision.classify` / `vision.ocr` / `vision.detect_people` | one-off analysis | `id`, … |
| `vision.similarity` | "find more like this" | `id`, `limit`, `days` |
| `vision.index` | batch-analyze the library into the persistent index | `days`, `redo`, `limit` |
| `video.sample_frames` | peek into a video without exporting | `id`, `count`, `interval_s` |
| `video.transcribe` | speech → text (on-device) | `id`, `language` |
| `media.export` | stage originals for download | `ids[]`, `preset` (original/720p/1080p) |
| `clear_exports` | free phone space when done | — |

Rows from `media.search` look like:

```json
{"id": "0AE2E2FC-…/L0/001", "filename": "IMG_8417.JPG", "media_type": "image",
 "width": 4284, "height": 5712, "created": "2026-09-07T17:29:30Z",
 "size_bytes": 5182609,
 "vision": {"labels": ["outdoor", "sky", "blue_sky"], "faces": 0}}
```

## 3. Content search (the fast path)

If the vision index covers the window, **search by meaning before exporting**:

```bash
call media.search '{"days":30,"has_label":"beach","limit":10}'
call media.search '{"days":30,"has_text":"receipt","limit":10}'   # OCR text
call media.search '{"days":30,"with_people":true,"limit":10}'     # faces/people
```

Empty results for a window = likely not indexed yet. Index it, then retry:

```bash
call vision.index '{"days":30,"limit":200}'     # incremental; skips known ids
```

Run response: `{"indexed": N, "skipped": M, "failed": 0, "total_indexed": T}`.
Roughly ~1 asset/second; index in batches (≤200) rather than the whole library.

## 4. Download originals (data plane ≠ control plane)

MCP results stay small. Media bytes flow over ranged HTTP:

```bash
# 1. pick assets by content, then stage them
URL=$(call media.export "{\"ids\":[\"$IDS\"],\"preset\":\"720p\"}" \
      | jq -r '.result.content[0].text | fromjson | .exports[0].url')

# 2. pull with resume support (videos can be GBs)
curl -C - -o clip.mp4 "$PHONE$URL"

# 3. housekeeping — the phone has finite disk
call clear_exports '{}'
```

Prefer `preset=720p` for video drafts; `original` only when quality matters.
**Inspect before pulling**: `media.thumbnail` / `video.sample_frames` /
`vision.classify` are free compared to a 2 GB transfer.

## Rules

- **Never** ask for base64 media in a tool result; never inline media bytes in
  chat. JSON + `/files/` URLs only.
- **Content search first, export second.** Filter with the index, verify with
  thumbnails/frames, export only the winners.
- **Always `clear_exports`** after downloading — it deletes the staged files
  from the phone.
- Long batch calls (`vision.index`, `video.transcribe`) can exceed a 120 s
  curl timeout — raise `-m` for those.
- iOS suspends the listener when the app backgrounds; if calls start timing
  out, ask the user to keep Neox foregrounded (ideally plugged in).
- The phone is a personal device on a home LAN: LAN-only, no auth — never
  tunnel it to the public internet.

## Workflow recipes

**"Build a vlog from yesterday"**
1. `media.search {"days":2}` (or the user's date range) → skim `vision` labels
2. `vision.index {"days":2}` if rows lack a `vision` summary
3. `media.search {"days":2,"has_label":"…","with_people":true}` → shortlist
4. `video.sample_frames` / `media.thumbnail` to verify picks
5. `media.export` shortlist → `curl -C -` → edit locally → `clear_exports`

**"What does this screenshot say?"**
`media.search {"media_type":"image","has_text":"…","limit":5}` or
`vision.ocr {"id":"…"}` for one asset.

**"Pull everything since Friday off my phone"**
`media.search {"after":"<iso>","limit":500}` paging with `offset` →
`media.export` in batches of ~10 → ranged downloads → `clear_exports`.

## When Neox isn't installed

The phone needs the Neox app (repo: `free2/neox`) built and installed —
`scripts/remote-deploy.sh` in that repo does sync → build → install → launch →
health check. That is a dev task, not an agent task: point the user at it
rather than attempting a remote iOS build from here.
