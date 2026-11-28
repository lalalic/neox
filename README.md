# Neox

## Neo Master: one Mac for everything

The Neo iPhone home screen discovers nearby Neo Master Macs. Select one
machine there; Desktop, Commands, and agent handoff use that same selection.
The Mac advertises its name and HTTPS MCP URL through Bonjour, **never any
credential**. Previously saved Macs remain usable away from home Wi-Fi.

Only the selected Mac's access code and screen-sharing account/password are
stored in the iPhone Keychain. If the Mac announces a different public domain,
the iPhone requires its access code again; it never forwards an existing secret
to an unverified Bonjour address. Connection details remain in Advanced setup.

Desktop uses the authenticated `/vnc` WebSocket route on that Mac's existing
HTTPS gateway. macOS Screen Sharing is enabled only on loopback; public port
5900 and a separate legacy VNC password are not required. Tap/click,
pinch/zoom, pan, scroll, and long-press/right-click operate the real desktop.
A dedicated password key enters the saved Mac password into the focused Mac
input when the owner explicitly taps it. Closing or leaving the view ends
the session.

Neo Mobile provides four compact **top navigation** buttons (Chat, Jobs, Review, Connector), keeping the chat composer against the bottom safe area without a bottom tab bar. Connector uses the phone server's actual state to color its top icon/label: green when running, orange while idle/starting, and red on failure. The redundant Connector page title/status banner has been removed; Neo Master connectivity remains visible inside the page. The Connector includes the existing iPhone media MCP server so a desktop agent can search, analyze, and pull photos/videos over Wi-Fi.

## Neo Mobile Orchestrator Chat

Chat uses the **already paired** Neo Master's HTTPS origin and Keychain bearer;
no extra Master login or independent Chat Gateway provider is required. The
current transport is Models-backed `/orchestrator-chat/*` REST/SSE rather than
`chat_report` MCP calls: `POST /messages` returns durable acceptance (202),
`GET /events` delivers the complete reply, `GET /pending` reconciles dropped
SSE or a resumed app, and `POST /ack` follows local persistence. The phone
owns both displayed history and a protected, idempotent outbox; reusing the
same `com.neox.app` bundle identity during an in-place upgrade preserves its
saved Master credential and local data. A separate staging bundle cannot
assume access to the production App's Keychain.

Ordinary completed chat replies appear in bubbles without APNs; attention,
failures, and owner actions may notify. The local history trash clears only
this phone's visible records. Models does **not** retain a second permanent
chat transcript; pending operational messages are retained until ACK and
then their text and attachments are scrubbed. For the precise envelope,
handoff, and endpoint semantics, see the
[Orchestrator Chat contract](https://github.com/lalalic/neo/blob/main/docs/chat-gateway-orchestrator.md).

A real iPhone/NeoUse acceptance test must verify the text entered the composer
and that both the owner's bubble and complete assistant reply survive a
relaunch. A successful automation tap alone is not proof of message delivery.

## Shared DuplexVoiceKit package (under development)

The reusable voice SDK lives at [`Packages/DuplexVoiceKit/`](Packages/DuplexVoiceKit/)
with its own `Package.swift`, `LICENSE`, public protocol surface and tests.
`project.yml` registers it as a **local** Swift package and links the
`DuplexVoiceKit`, `DuplexVoiceApple` and `DuplexVoiceLiveKit` products to NeoxApp.
The package is product-neutral; it is not a Neo chat transport or server.
Other local iOS projects can reference this package by path. It is not yet a
standalone remotely installable GitHub Swift package because its manifest is
nested inside this repository.

The current package implements generic STT/TTS protocols, Apple speech adapters,
LiveKit 2.19 local capture and TTS sentence merging/FIFO playback coordination.
The **LiveKit audio output**, real VAD/barge-in and iPhone full-duplex E2E are
still outstanding. Adding a package dependency does **not** enable a Voice UI
or replace the existing Chat composer dictation implementation.

Run `swift test --package-path Packages/DuplexVoiceKit` for its package tests.
`xcodegen generate` refreshes the local-package reference for the iOS target.

## Neo Mobile Review Inbox

The Review Inbox keeps submissions on the phone after Approve or Request Changes.
The Review page has no redundant title or refresh button. Pull down anywhere
on the list (including when empty) to synchronize with Neo Master; the existing
foreground/periodic refresh remains. The single list is sorted newest-first and
displays a per-review status icon (pending, approved, changes requested,
preview-only, or superseded). The app
retains the review decision, feedback, submitted time and preview identity;
submission acceptance does **not** mean that the owning Job has finished.
Completed reviews are read-only and cannot accidentally submit another decision.
Delete individual reviews from their preview menu, row menu, or swipe gesture. Deletion is phone-owned and prevents a late APNs repeat from restoring
the deleted row. Items pending feedback delivery cannot be deleted. Previously
deleted reviews cannot be recovered automatically.

The review metadata is stored on the phone across app relaunches. Video
replay still requires the Neo Master to retain the referenced Markcut compiled
preview and media; this feature does not copy full videos into phone storage.

In Chat, the trash icon immediately to the right of the `+` opens a
confirmation to clear the visible message history *on this phone only*. Models
keeps no second permanent Chat feed; pending outbox messages/attachments are
still delivered, and ACKed operational content is scrubbed.
The local clear cutoff persists across app restarts, and future messages appear
normally.

## Relay Jobs on Neo Mobile

The Jobs tab first reads the selected Master's authenticated `/relay/api/mobile/*` REST routes, with legacy Chat Gateway MCP fallback only when those routes are absent. Active Jobs are listed first, followed by recent terminal Jobs. Each row shows the title (or Job ID fallback), the Gateway-projected runtime status (including `WAITING`, `IDLE`, `REVIEWING`, and `MERGE_PENDING`), and **creation time** (from Relay `createdAt`, not the last update). The detail view starts with metadata collapsed and uses only the authenticated, credential-redacted Dashboard event history (`GET /relay/api/events?job=ID&repo=REPOSITORY&limit=60`). It preserves canonical event IDs, task IDs, timestamps and authorized details. No legacy activity projection or MCP fallback is supported for history. An unavailable canonical endpoint is a load error, not an empty or reduced timeline.

Jobs are fetched in pages of **20**, not as a full inventory: pull down to reset to the newest 20, or swipe up to the bottom to append 20 more. The list does not automatically reset while scrolling. Open a Job to refresh its activity. Eligible Jobs expose a swipe **Cancel** action only when the authenticated gateway advertises `cancellable`; cancellation asks for confirmation and the phone requires the Master's authoritative `CANCELLED` readback. The request uses the exact repository and Job ID, not a PR number. Older gateways that omit the capability cannot offer cancellation. Connectivity failures preserve the last good snapshot rather than treating it as an empty authoritative state.

Jobs now subscribe to the selected Master's authenticated \`/relay/api/mobile/events\` SSE endpoint. The stream carries only a fixed \`{"refresh":true}\` wake-up and never includes raw Job, Task or private message content; the app re-reads Jobs and the open Activity timeline from the authenticated REST routes. Opening an Activity screen shows a loading state while fetching; failed fetches retain prior events and expose Retry rather than claiming that the Master lacks Activity. Older Masters without the SSE route remain readable with pull-to-refresh.

The SSE client decodes the raw byte stream rather than using `URLSession.AsyncBytes.lines`: Foundation may skip empty lines, but SSE requires empty lines to delimit consecutive events. The byte decoder preserves LF and CRLF separators and enforces bounded lines; unit and real-device MVP tests cover the behavior.

The Relay/mobile gateway owns the source of truth and authorization: [Chat Gateway Skill](https://github.com/lalalic/neo/blob/main/skills/chat-gateway/SKILL.md) and [Mobile Job controls](https://github.com/lalalic/neo/blob/main/skills/chat-gateway/docs/neo-mobile-job-controls.md). The phone does not mutate Relay's SQLite store or infer completion from a submission receipt.

## NeoY v2 design principles

NeoY v2 is the Mac-side authenticated MCP gateway and native capability host.
The canonical architecture contract for all work under `mac/NeoY` is
[`mac/NeoY/docs/design-principles.md`](mac/NeoY/docs/design-principles.md).
That document owns the principles, Architecture Lens, and planning/review
requirements; this README intentionally does not duplicate them.

NeoY bundles and federates the upstream MacBridge MCP runtime for generic Mac
developer primitives: shell execution, background jobs, filesystem, PTY,
read-only Codex thread access, and `apply_patch`. Those capabilities are not
reimplemented in Swift. NeoY remains the signed authenticated host, remote
authorization and federation boundary, native/TCC capability owner, cluster
router, and public facade.

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

## Create a Vlog through iCloud Drive

The status screen has a **Create Vlog** action for asynchronous Vlog creation when the phone and Mac do not need to be on the same LAN.

First use:

1. Tap **Create Vlog**.
2. Tap **Choose Vlog Inbox** and select an iCloud Drive folder named `Vlog Inbox`.
3. Select photos/videos, optionally add an instruction, then tap **Create Vlog Submission**.

Neox stores the selected folder permission and writes one submission directory:

```text
Vlog Inbox/<submission-id>/
├── media/...
└── manifest.json
```

`manifest.json` is schema version 1 and is written only after every selected media file has been fully materialized. It is the ready signal consumed by Neo Vlog's Mac-side watcher; Neox does not create Relay Tasks itself.

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
- **Direct bridge handoff**: the intent browses for `_neoy._tcp` (the
  Bonjour service your desktop agent's bridge advertises — see the
  `neox-phone-mcp` skill) and POSTs the message straight to it. No Shortcut
  hop. If no bridge is on the LAN, the message lands on the clipboard as a
  fallback and the dialog says so.
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

## Tools (15)

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
| `media.clear` | free phone space after downloads | — |
| `agent.handoff` | self-test the phone→bridge handoff path (Bonjour discovery + POST) | `instruction` |
| `agent.pilot` | remote UI automation of this app (self-testing) | `command`: snapshot/tap/tap_xy/type/swipe/long_press/find/scroll_to/pick/screenshot |
| `agent.demo` | visual demo overlays (spotlight, caption, TTS…) | `command`: step/spotlight/annotate/caption/say/cursor/highlight/clear/pause/resume/wait/start_recording/stop_recording |
| `tour.start` | validate and stage a human Capture Tour | `manifest` (JSON string) |
| `tour.status` | inspect tour progress and accepted shot references | — |
| `tour.cancel` | clear the active tour without deleting media | — |

## Capture Tour Runner

`tour.start` accepts one versioned, ordered shot manifest. Neox persists the
session, shows a Start/Resume card on the status screen, and guides the human
through each independent shot: live camera preview, script/instruction,
framing guidance, target-duration progress (never an automatic cutoff), then
Stop → Retake / Accept / Skip. Accepted takes are stored in the app's existing
`/files/` cache and `tour.status` returns deterministic `shot_id` to
`/files/<name>` references. Camera and microphone access are requested only
when the runner is opened. The runner applies camera, orientation, and lens
preferences where supported, with deterministic fallback notes. Talking-head
shots can also show non-blocking Vision/luminance guidance for face presence,
approximate distance, centering, and low light.

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
call media.clear '{}'
```

## Building

Requirements: Xcode 16+ (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen),
an Apple Developer team for device signing. UI automation and demo tools use the public AppCopilotKit Swift Package (`https://github.com/lalalic/app-copilot-kit`).

```bash
xcodegen generate          # → Neox.xcodeproj
open Neox.xcodeproj        # run on simulator or device
```

See `AGENTS.md` for repo layout and the machine-room notes (remote build,
signing quirks, deployment).

## TestFlight release

On Neo Master, use `scripts/testflight.py doctor` to verify the existing App Store Connect API key, target app/build numbers, and cached signing; then `scripts/testflight.py release --bump` to archive and upload. To reuse an existing signed Release archive, run `scripts/testflight.py release --archive /absolute/path/to/Neox.xcarchive`. Check final Apple status using `scripts/testflight.py status --build NUMBER`. See [scripts/README-testflight.md](scripts/README-testflight.md) for shared-skill preflight, security, verification, and TestFlight tester-group gates. The script never relies on the intermittent Xcode GUI account-selection state.

## Scope notes

- **LAN only.** No auth (personal device on home WiFi), no relay, no CDN.
- **Foreground-first.** iOS suspends sockets when backgrounded; the app is
  meant to be used plugged in ("charging dock"). Keep the screen on for
  reliable serving.
- Only the status screen is human-facing; every feature is agent-first.

### Voice conversation in Chat (device integration)

The Chat composer has a dedicated **Voice conversation** button in addition to
its existing, manual dictation button. The inline voice toggle uses
`Packages/DuplexVoiceKit`: LiveKit local microphone/voice processing, Apple
speech recognition and synthesized PCM playback through LiveKit local
`SoundPlayer`. No modal voice sheet is shown: icon appearance and accessibility
value communicate Starting, Listening, Thinking, Speaking, and Error. Interim
speech recognition text appears directly in the Chat composer, and stopping
before utterance commit retains that pending text for editing. Automatically
committed voice turns preserve any previously typed draft.
Voice turns use the same durable Chat outbox, REST/SSE request
IDs and on-device assistant history as typed messages. The voice client only
speaks the matched terminal assistant reply; it ignores unrelated replies and
non-terminal placeholders. The microphone is stopped by tapping the icon again,
switching away from Chat, or sending a manually edited message. The phone never directly connects to Events Bus or
LiveKit Server.

STT/TTS can be replaced through the shared `SpeechRecognitionProvider` and
`SpeechSynthesisProvider` protocols. This version uses the default Apple
providers; they need microphone/speech permission and a configured Chat
master. The energy VAD is a local utterance segmentation heuristic. Real iPhone
speakerphone echo rejection, barge-in timing, Bluetooth and continuous
conversational recognition require physical-device validation before claiming
production-quality full duplex; in particular LiveKit SoundPlayer's local audio
route does not prove its playback is used as the AEC reference.
