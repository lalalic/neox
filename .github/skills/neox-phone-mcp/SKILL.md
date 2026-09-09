---
name: neox-phone-mcp
description: >-
  Use an iPhone as a local MCP media server via the Neox app: search the
  phone's photo/video library by content (vision index), analyze on-device
  (classify/OCR/people/transcribe), and pull originals over WiFi with ranged
  HTTP. Includes the Neoy bridge — a Bonjour-advertised HTTP endpoint
  you implement + run (via session hook) that receives "Run Agent Task"
  handoffs from the phone. Use when a task needs the user's phone media:
  "find photos of X", "pull recent videos off my phone", "build a vlog from
  my camera roll", "OCR my screenshots", or any macOS agent flow mentioning Neox.
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
| `media.clear` | free phone space when done | — |

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

## Workflow recipes

**Receiving "Run Agent Task" handoffs — implement the bridge (do this at session start)**

The phone's **Run Agent Task** intent produces the handoff message (user
instruction + the phone's MCP URL). There is no built-in transport to your
chat — so *you* implement and run a **bridge**: a small HTTP endpoint on this
machine that receives the handoff and is discoverable by the phone via
Bonjour.

**The discovery contract** (mirrors how the phone advertises `neox._mcp._tcp`):

- The bridge (codename **Neoy**) advertises `_neoy._tcp` on the LAN. Use
  the machine name as the instance name AND in TXT `host=` — the phone's
  status screen shows it, so users see e.g. "mac111" instead of a cryptic
  "neox-agent". Neox resolves this automatically when Run Agent Task fires —
  no IP or port is ever configured on the phone.
- The Shortcuts "Get Contents of URL" POST (below) is only a legacy fallback
  for older Neox builds; current builds hand off directly over Bonjour.

**Who knows what:** the app never hardcodes the bridge address — it either
resolves it via Bonjour (target state) or the Shortcut holds the `.local` URL
(interim). The bridge is stateless: POST body → inbox file; you read the
inbox.

1. **Implement** — write this as `neox-bridge.py` in your workspace (or
   `/tmp`), then start it:
   ```bash
   cat > /tmp/neox-bridge.py <<'PY'
   import subprocess, http.server, socketserver
   PORT = 8787
   class H(http.server.BaseHTTPRequestHandler):
       def do_POST(self):
           body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
           open('/tmp/neox-inbox.txt', 'a').write(body + '\n---\n')
           self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
       def log_message(self, *a): pass
   socketserver.TCPServer.allow_reuse_address = True
   # Bonjour: the phone resolves _neoy._tcp to find us. Instance name and
   # host= TXT carry the machine name for display; ip= lets the phone skip
   # mDNS resolution entirely and connect directly (iOS stalls on .local).
   import socket
   HOST = socket.gethostname().split('.')[0]
   # Best-effort LAN IP: the one the default route uses.
   try:
       s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
       s.connect(('8.8.8.8', 80)); IP = s.getsockname()[0]; s.close()
   except Exception: IP = '127.0.0.1'
   subprocess.Popen(['dns-sd', '-R', HOST, '_neoy._tcp', '.', str(PORT),
                     'path=/agent', f'host={HOST}', f'port={PORT}', f'ip={IP}'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
   socketserver.TCPServer(('0.0.0.0', PORT), H).serve_forever()
   PY
   nohup python3 /tmp/neox-bridge.py >/dev/null 2>&1 &
   sleep 1
   echo "bridge up — inbox: /tmp/neox-inbox.txt · shortcut URL: http://$(scutil --get LocalHostName).local:8787/agent"
   ```
2. **Start it via your session-start hook** so handoffs are always receivable,
   not only after you remember to run it. Wire `neox-bridge.py` into whatever
   session-lifecycle hook your harness has (a `SessionStart`/`session_start`
   hook config, a startup script, or your shell profile). Idempotency: check
   first so parallel sessions don't double-bind —
   ```bash
   curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8787/agent -d ping
   # 000 → not running → start it; anything else → already up
   ```
3. **Consume**: poll `/tmp/neox-inbox.txt` (or `tail -f`) — each entry is a
   handoff: the instruction plus the phone's MCP URL. Then act with the tools
   in this skill (search → index → export → download).

Tell the user (only if they run an older Neox build): the interim Shortcuts
setup POSTs to the bridge's `.local` URL —
*Shortcuts → Run Agent Task (Neox) → Get Contents of URL →
`http://<mac>.local:8787/agent`, Method POST, Body = Provided Input.*
Current builds need no Shortcut at all.

Fallbacks: the message is also on the phone's clipboard (paste into chat).
Stop the bridge when the session's work ends (`pkill -f neox-bridge.py`) —
unless the session hook is meant to keep it alive for future handoffs; it is
a plain LAN-only HTTP endpoint, never expose it beyond the home network.

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

The phone needs the Neox app built and installed on it first (Xcode + an
Apple Developer team; the app's own repo has an `AGENTS.md` with the machine
notes). That is a dev task, not an agent task: point the user at the repo's
build instructions rather than attempting a remote iOS build from here.
