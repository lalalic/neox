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
`submitted` receipts and no fabricated completion. The authenticated
`voice.complete` callback accepts an answer only for the matching pending
session and correlation ID, changes the receipt to `completed`, and speaks the
answer once. This callback path is implemented; automatic retrieval/delivery of
ChatGPT replies to that callback is **not** implemented. An external trusted
caller must invoke `voice.complete` with the actual completed reply. Early
callbacks (before the submission acknowledgement returns) are supported. Voice input is never interpolated into shell commands.

To reproduce the selected Xcode test suite, first run `xcodegen generate` from
`mac/NeoY` (the generated `.xcodeproj` is ignored by Git), then run:

```sh
xcodebuild test -project NeoY.xcodeproj -scheme NeoY -destination 'platform=macOS' \
  -only-testing:NeoYTests/VoiceSessionTests CODE_SIGNING_ALLOWED=NO
```

The selected run must report a nonzero number of executed tests; exit code 0
alone is not evidence of test discovery. The test suite checks submitted-vs-
completed TTS behavior, explicit mute, stop, failure and safe intent routing.
