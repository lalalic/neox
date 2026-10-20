# NeoY Listen & Talk

NeoY provides a first single-speaker voice path through the protected
`voice.session` intent facade. The menu-bar item **Listen & Talk…** opens the
same controls exposed to trusted MCP callers.

## Lifecycle

`voice.start` is an explicit session-start acknowledgement: it returns the
current state and session ID after permission checks and engine startup. It is
not speech recognition and it is not command completion. A recognized turn
gets a separate correlation ID and a `submitted`, `completed`, or `failed` receipt. `voice.stop`
ends capture; `voice.mute` pauses buffer delivery while keeping the session
visible. Listening is bounded to 60 seconds per explicit start and never starts
in the background.

`voice.inject` is the repeatable no-microphone path. It runs the same command
adapter and TTS completion path as recognized speech. `voice.speak` is a TTS
smoke path that uses the selected macOS output device.

## Permissions and limitations

The first `voice.start` requires a human to approve Microphone and Speech
Recognition in macOS System Settings. NeoY reports denial/unavailable-device
errors in the UI and tool result; it does not bypass TCC. Chinese and English
use `zh-CN` and `en-US` Speech locales. The current path has one speaker,
manual start/stop/mute, a 60-second turn bound, and no wake word, diarization,
barge-in, or voice identity authorization. Audio is not exposed as a network
service. Roku control remains downstream of the command adapter.

The `Neo status` / `Neo 状态` intent runs the authenticated NeoY gateway
`status` command and speaks the returned result only after the tool completes.
Other recognized speech is sent through the protected ChatGPT interface. This
interface acknowledges **submission**, not an assistant answer; these turns have
`submitted` receipts and no fabricated completion. The protected `voice.reply`
callback accepts ordered text segments only for the matching active session and
pending correlation ID. Sequence starts at zero; identical retries return the
same receipt without replaying audio, while stale, conflicting, or out-of-order
segments are rejected. `final=true` completes the reply only after macOS speech
playback finishes; each segment reports `delivered` only after its playback
finishes. `voice.complete` remains the one-segment final compatibility command.
`voice.cancel_audio` stops speech without cancelling submitted command or tool
work. Replies go to the session's configured local output; callers cannot
choose a room or destination. These MCP tools remain protected behind the
existing NeoY authentication boundary.

Automatic retrieval/delivery of ChatGPT replies is **not** implemented. An
external trusted caller must invoke `voice.reply` with the actual response.
Submission acknowledgements remain `submitted`; typed turns stay silent unless
an explicit voice command is used. Voice input is never interpolated into shell
commands.

To reproduce the selected Xcode test suite, first run `xcodegen generate` from
`mac/NeoY` (the generated `.xcodeproj` is ignored by Git), then run:

```sh
xcodebuild test -project NeoY.xcodeproj -scheme NeoY -destination 'platform=macOS' \
  -only-testing:NeoYTests/VoiceSessionTests CODE_SIGNING_ALLOWED=NO
```

The selected run must report a nonzero number of executed tests; exit code 0
alone is not evidence of test discovery. The test suite checks submitted-vs-
completed TTS behavior, explicit mute, stop, failure and safe intent routing.

## Persistent ChatGPT Project binding (Job 482 reviewer correction)

The ChatGPT submission path now invokes `chatgpt turn` with a verified
`project_id` and `thread_id` instead of creating a Temporary Chat on
every spoken utterance. Configure `NEOY_VOICE_CHATGPT_PROJECT_ID` and
`NEOY_VOICE_CHATGPT_THREAD_ID` **in the NeoY process environment** only
after Browser Workspace returns real stable IDs. Do not use a tab ID or invent
either identifier. Missing binding fails with a typed voice receipt and no
ChatGPT submission. Both values are routing metadata, not credentials.

This correction does **not** implement the LiveKit audio transport. The current
macOS synthesizer speaks to the local system output, not an authenticated LiveKit
room participant. NeoY's native app owns local microphone permission, while
a future Worknode gateway must own LiveKit rooms, remote audio streams, streaming
STT/TTS, room membership, barge-in and playback receipts. Audio cancellation
must never cancel the submitted ChatGPT/tool task.

### Acceptance evidence and remaining gates

- 2026-10-18: `xcodebuild test -project NeoY.xcodeproj -scheme NeoY
  -destination 'platform=macOS' -only-testing:NeoYTests/VoiceSessionTests
  CODE_SIGNING_ALLOWED=NO`: **17 tests, 0 failures**.
  Covers reply correlation, ordered sequence, deduplication, invalid/stale
  segments, cancellation, transcript dispatch and local TTS receipts.
- A NeoY trusted cluster `invoke work exec` attempt returned
  `Could not connect to the server`; the LiveKit container and audio bridge
  could not be inspected or tested in this execution.
- Browser Workspace's most recent project setup failed at its project-name
  field; the `neo` ChatGPT MCP app was disconnected. See
  `neo-voice-project-setup-evidence.md`.
- **Not accepted as real speech E2E:** no verified ChatGPT Project/thread binding,
  real LiveKit room participants, recorded source speech, streaming STT, streamed
  voice reply, or measured playback latency. Do not promote a synthetic or
  no-mic test to real-speech acceptance.

- 2026-10-20: the registered `voice.session` facade now has a no-microphone
  round-trip injection test through correlated `voice.reply` segments. Focused
  VoiceSession suite: **18 tests, 0 failures**. The test uses a fake synthesizer;
  it verifies tool routing, sequence, and receipts only. It does not close the
  LiveKit, ChatGPT Project, or real-speech E2E gates. Latest Browser Workspace
  project setup still fails to find the project-name field; ChatGPT's `neo` app
  reports disconnected. NeoY cluster `status work` returns
  `Could not connect to the server`, so the existing Worknode LiveKit container
  could not be inspected or exercised. See
  `neo-voice-project-setup-evidence.md`.
