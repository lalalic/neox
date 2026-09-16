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

## Capture Tour workflow

For a human-guided recording session, call `tour.start` with a JSON-encoded
version-1 manifest containing `tour_id`, `title`, and ordered `shots`. Each
shot may specify `instruction`, `script`, `target_duration_s`, `camera`,
`orientation`, `lens`, `framing`, and advisory `quality` preferences. The
phone status screen exposes Start/Resume; the human records and reviews each
shot with Retake, Accept, or Skip. Use `tour.status` to read progress and the
accepted `shot_id` → `/files/...` references. Target duration and quality
warnings are advisory; the runner never hard-stops or blocks acceptance. Use
`tour.cancel` to clear a pending or active tour without deleting unrelated
media.

## Workflow recipes

**Receiving "Run Agent Task" handoffs — run the bridge (do this at session start)**

The phone's **Run Agent Task** intent sends the handoff message (user
instruction + the phone's MCP URL) to a small HTTP endpoint on this machine —
the **bridge** (codename **Neoy**) — which it finds via Bonjour. Nothing is
configured on the phone; if the bridge isn't running, the message falls back
to the phone's clipboard.

### The bridge contract

Two one-way pipes. Both bodies are the complete handoff message as plain
UTF-8 text (`Content-Type: text/plain`) — never parse it; it is already a
valid user message.

1. **Phone → bridge** — `POST /agent`. The phone discovers the bridge by
   browsing `_neoy._tcp` on the LAN and reading its TXT records (`host=`
   machine name, `port=`, `ip=` LAN address — `ip=` lets the phone skip mDNS
   resolution, which stalls on iOS). A `200` response means delivered.
   Advertise the machine name as the instance name so the user sees e.g.
   "studio-mac" on the phone's status screen, not a cryptic "neox-agent".
2. **Bridge → session (turn start)** — `GET /agent/next?timeout=25`.
   Long-poll: responds with the oldest pending handoff as the body and
   deletes it (FIFO, at-most-once), or `204` after `timeout` seconds when
   nothing is pending. The session-side watcher loops on this endpoint; each
   returned body starts exactly one new agent turn — as if the user had sent
   it. `GET /agent/peek` returns the same body without consuming (debug /
   recovery after a crashed watcher).

Implementation notes: the server must hold the long-poll GET open without
blocking POSTs (threaded server); pending handoffs live as one file each
under `~/.neoy/inbox/`.

### 1. Run it

Check first — parallel sessions must not double-bind:

```bash
curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8787/agent -d ping
# 000 → not running → start it; anything else → already up
```

```bash
mkdir -p ~/.neoy && cat > ~/.neoy/neox-bridge.py <<'PY'
import glob, os, socket, socketserver, subprocess, time
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORT = 8787
INBOX = os.path.expanduser("~/.neoy/inbox")   # one file per pending handoff
os.makedirs(INBOX, exist_ok=True)

def pending():
    return sorted(glob.glob(os.path.join(INBOX, "*.txt")))

class H(BaseHTTPRequestHandler):
    def do_POST(self):                        # phone → bridge
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if len(body) >= 8:                    # tiny bodies ("ping") are health checks
            with open(os.path.join(INBOX, f"{time.time_ns()}.txt"), "wb") as f:
                f.write(body)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    def do_GET(self):                         # session → bridge (long-poll)
        q = parse_qs(urlparse(self.path).query)
        deadline = time.time() + float(q.get("timeout", ["0"])[0])
        consume = "/next" in self.path
        while True:
            files = pending()
            if files:
                data = open(files[0], "rb").read()
                if consume:
                    os.unlink(files[0])
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers(); self.wfile.write(data)
                return
            if time.time() >= deadline:
                self.send_response(204); self.end_headers(); return
            time.sleep(0.5)

    def log_message(self, *a): pass

# Bonjour: the phone resolves _neoy._tcp to find us. Instance name and host=
# TXT carry the machine name for display; ip= lets the phone skip mDNS
# resolution entirely and connect directly (iOS stalls on .local).
HOST = socket.gethostname().split(".")[0]
try:                                          # best-effort LAN IP
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.connect(("8.8.8.8", 80)); IP = s.getsockname()[0]; s.close()
except Exception:
    IP = "127.0.0.1"
subprocess.Popen(["dns-sd", "-R", HOST, "_neoy._tcp", ".", str(PORT),
                  "path=/agent", f"host={HOST}", f"port={PORT}", f"ip={IP}"],
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
socketserver.ThreadingTCPServer.allow_reuse_address = True
# ThreadingTCPServer, not TCPServer: a held-open long-poll GET must not block POSTs.
socketserver.ThreadingTCPServer(("0.0.0.0", PORT), H).serve_forever()
PY
nohup python3 ~/.neoy/neox-bridge.py >/dev/null 2>&1 &
sleep 1
echo "bridge up — http://$(scutil --get LocalHostName).local:8787/agent"
```

Start both bridge and watcher from your session-start hook (a
`SessionStart`/`session_start` hook config, a startup script, or your shell
profile), so handoffs are receivable even when you're idle.

### 2. Wire it to your turn loop (the watcher)

The bridge only holds handoffs; *your harness* starts turns. Whatever
mechanism your harness has for injecting a user message — a chat-input API,
a headless one-shot prompt, a hook — point it at the bridge:

```bash
while true; do
  msg=$(curl -s -m 30 "http://127.0.0.1:8787/agent/next?timeout=25")
  [ -n "$msg" ] && start_agent_turn "$msg"    # ← your harness's injection point
done
```

If your harness can't inject turns programmatically, poll `GET /agent/peek`
whenever you get control and confirm with the user before acting on a
pending handoff.

### 3. Housekeeping

- Multiple agent sessions running watchers on one machine: handoffs are
  at-most-once — whichever session polls first consumes them.
- Legacy apps: some installed versions use a Shortcuts "Get Contents of URL"
  POST to `http://<mac>.local:8787/agent` (Method POST, Body = Provided
  Input) — the same endpoint, so no bridge change is needed. The current
  App Store release needs no Shortcut at all.
- If the bridge is down, the message is also on the phone's clipboard —
  the user can paste it into chat.
- The bridge is a plain LAN-only HTTP endpoint: never expose it beyond the
  home network. Stop it when the session's work ends (`pkill -f
  neox-bridge.py`) unless the hook is meant to keep it alive for future
  handoffs.

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
