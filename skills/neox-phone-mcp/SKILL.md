---
name: neox-phone-mcp
description: >-
  Use an iPhone as a local MCP media server via the Neox app: search the
  phone's photo/video library by content (vision index), analyze on-device
  (classify/OCR/people/transcribe), and pull originals over WiFi with ranged
  HTTP. Includes NeoY — the native macOS companion and Bonjour handoff endpoint
  you implement + run (via session hook) that receives "Run Agent Task"
  handoffs from the phone. Use when a task needs the user's phone media:
  "find photos of X", "pull recent videos off my phone", "build a vlog from
  my camera roll", "OCR my screenshots", or any macOS agent flow mentioning Neox.
  The same skill also covers **NeoY**, the native macOS MCP companion for
  guided Capture Tours and agent-driven product-demo recording.
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

1. **Bonjour** — the app advertises `neox._mcp._tcp`; resolve it to an IP:port:
   ```bash
   # browse for the service, then resolve the first result
   dns-sd -B _mcp._tcp                 # browse (Ctrl-C to stop)
   dns-sd -L "neox" _mcp._tcp local    # resolve name → host/port
   dns-sd -G v4 <host-from-L>          # host name → IPv4
   ```
2. **ARP scan** — probe port 9223 on hosts whose ARP entry looks like an iPhone:
   ```bash
   arp -a | awk '/iphone/{print $2}' | tr -d '()'   # candidate IPs
   curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST http://<ip>:9223/mcp -d '{}'
   ```
   A `200` means Neox is there. (ARP labels lie — DHCP moves IPs between
   devices; always confirm by probing, not by name.)
3. **Ask the user** to open Neox and read the endpoint from the status screen
   (green dot = server running; it also shows the raw URL as a fallback when
   Bonjour is flaky on some networks).

No `200` anywhere? The phone is likely locked-with-app-closed, or Local Network
permission was just granted without an app restart. Ask the user to open Neox
on the phone (screen on), then re-probe.

## 2. Call tools (raw JSON-RPC over HTTP)

```bash
PHONE=http://<phone-ip>:9223     # from discovery above
call() { curl -s -m 120 -X POST $PHONE/mcp -H 'Content-Type: application/json' \
         -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",
              \"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
```

Discover the live tool list first (`tools/list`), then:

Before the first phone-dependent operation, start an explicit phone transaction:

```bash
TX=$(call phone.transaction.start '{"label":"Vlog media pull","reason":"NeoX must stay foregrounded","timeout_minutes":30}' \
     | jq -r '.result.content[0].text | fromjson | .transaction_id')
```

While that transaction is active, tell the user to leave NeoX in the foreground.
After the final phone-dependent call (including `media.clear`), release the phone:

```bash
call phone.transaction.end "{\"transaction_id\":\"$TX\",\"outcome\":\"completed\"}"
```

Use `failed` or `cancelled` when that reflects the phone work. Matched end calls are
idempotent; a mismatched id does not release the phone. Transactions also expire after
their bounded timeout. After a successful end, do not ask NeoX to stay foregrounded unless
you start a new transaction; local desktop analysis, TTS, editing, and rendering can continue.

| tool | use for | key args |
|---|---|---|
| `phone.transaction.start` | begin the explicit NeoX foreground boundary | `label`, `reason`, `timeout_minutes` |
| `media.search` | find assets — incl. **content search** | `media_type`, `days`/`after`/`before`, `album`, `favorited`, `has_label`, `has_text`, `with_people`, `limit`, `offset` |
| `media.meta` | full EXIF/GPS + vision analysis for one asset | `id` |
| `media.thumbnail` | JPEG preview at `/files/` (inspect cheaply) | `id`, `max_side` |
| `vision.classify` / `vision.ocr` / `vision.detect_people` | one-off analysis | `id`, … |
| `vision.similarity` | "find more like this" | `id`, `limit`, `days` |
| `vision.index` | batch-analyze the library into the persistent index | `days`, `redo`, `limit` |
| `video.sample_frames` | peek into a video without exporting | `id`, `count`, `interval_s` |
| `video.transcribe` | speech → text (on-device) | `id`, `language` |
| `media.export` | stage originals for download | `ids[]`, `preset` (original/720p/1080p) |
| `media.clear` | free phone space when done | — |
| `phone.transaction.end` | end the NeoX foreground boundary when phone work is done | `transaction_id`, `outcome` |

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
call media.clear '{}'
```

Prefer `preset=720p` for video drafts; `original` only when quality matters.
**Inspect before pulling**: `media.thumbnail` / `video.sample_frames` /
`vision.classify` are free compared to a 2 GB transfer.

## Rules

- **Start `phone.transaction.start` immediately before phone-dependent work and call `phone.transaction.end` immediately after it** (normally after `media.clear`). Remaining desktop workflow must not require NeoX foreground after end.
- **Never** ask for base64 media in a tool result; never inline media bytes in
  chat. JSON + `/files/` URLs only.
- **Content search first, export second.** Filter with the index, verify with
  thumbnails/frames, export only the winners.
- **Always `media.clear`** after downloading — it deletes the staged files
  from the phone.
- Long batch calls (`vision.index`, `video.transcribe`) can exceed a 120 s
  curl timeout — raise `-m` for those.
- iOS suspends the listener when the app backgrounds; if calls start timing
  out, ask the user to keep Neox foregrounded (ideally plugged in).
- The phone is a personal device on a home LAN: LAN-only, no auth — never
  tunnel it to the public internet.

## NeoY macOS companion

Use **NeoY** for Mac-side capture, demo automation, focused Accessibility actions,
and NeoX phone media access. NeoY is the canonical replacement for Neox Tour Mac
and the standalone Python Neoy bridge.

- MCP endpoint: `http://127.0.0.1:9224/mcp`
- MCP Bonjour service: `_mcp._tcp`, instance `NeoY`
- Phone handoff service: `_neoy._tcp`, TCP `8686`, `POST /agent`
- Handoff queue: `GET /agent/next?timeout=0..30` and `GET /agent/peek`
- Demo and phone exports: `~/Library/Application Support/NeoY/exports`

Before relying on a tool, call `tools/list`; the live schema is authoritative.

### Demo workflow

Use the shared demo primitives from `~/Workspace/demo/contracts/primitives.md`:

```text
demo.start_recording
  -> demo.step
  -> demo.spotlight / demo.annotate / demo.caption / demo.say
  -> demo.cursor / demo.highlight / demo.clear
  -> demo.pause / demo.resume / demo.wait
  -> demo.stop_recording
```

Visual primitives and UI-driving actions are separate. Use
`accessibility.inspect` / `accessibility.resolve` to resolve UI targets, and
`computer.click`, `computer.type`, `computer.set_value`, `computer.key`,
`computer.scroll`, or `computer.drag` only when interaction is required.

Screen Recording permission is required for real MOV capture. Accessibility
permission is required for semantic UI inspection/actions. Explicit rectangle
target resolution remains deterministic without Accessibility permission.

### NeoX phone media

NeoY discovers the phone's `_mcp._tcp` endpoint or uses the exact MCP URL from
a phone handoff. Native wrapper tools are:

- `phone.status`
- `phone.media.search`
- `phone.media.meta`
- `phone.media.thumbnail`
- `phone.media.export`

`phone.media.export` delegates to NeoX `media.export` and downloads staged files
to `~/Library/Application Support/NeoY/exports/phone/`. NeoY does not recreate
the phone's media index.

## Capture Tour workflow

For a human-guided recording session, call `tour.start` with a JSON-encoded
version-1 manifest containing `tour_id`, `title`, and ordered `shots`. Use
`tour.status` for progress and accepted `/files/...` references, and
`tour.cancel` to clear a pending or active tour without deleting unrelated
media.

## Workflow recipes

**Receiving "Run Agent Task" handoffs**

NeoY owns the handoff endpoint. Do not start `neoy-bridge.py`, a PM2 `neo-y`
process, or a separate `dns-sd` bridge. The phone discovers `_neoy._tcp` and
sends the complete handoff message to `POST /agent` as `text/plain`. HTTP 200
means the native companion durably queued the handoff under `~/.neoy/inbox`.

Desktop consumers use:

```bash
curl -s 'http://127.0.0.1:8686/agent/peek'
curl -s 'http://127.0.0.1:8686/agent/next?timeout=25'
```

`peek` is non-consuming; `next` consumes FIFO and returns 204 on timeout. A
phone handoff may include the live NeoX MCP URL; NeoY remembers it for later
media calls. Keep the endpoint LAN-only and never expose it to the public
internet.

**"Build a vlog from yesterday"**
1. `media.search {"days":2}` (or the user's date range) → skim `vision` labels
2. `vision.index {"days":2}` if rows lack a `vision` summary
3. `media.search {"days":2,"has_label":"…","with_people":true}` → shortlist
4. `video.sample_frames` / `media.thumbnail` to verify picks
5. `media.export` shortlist → `curl -C -` → edit locally → `media.clear`

**"What does this screenshot say?"**
`media.search {"media_type":"image","has_text":"…","limit":5}` or
`vision.ocr {"id":"…"}` for one asset.

**"Pull everything since Friday off my phone"**
`media.search {"after":"<iso>","limit":500}` paging with `offset` →
`media.export` in batches of ~10 → ranged downloads → `media.clear`.

## When Neox isn't installed

Neox is on the App Store. If the phone doesn't have it, ask the user to
install it from there and grant Local Network and Photos permission on first
launch — no other setup is needed.
