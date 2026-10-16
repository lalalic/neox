# NeoY Listen & Talk

NeoY provides a first single-speaker voice path through the protected
`voice.session` intent facade. The menu-bar item **Listen & Talk…** opens the
same controls exposed to trusted MCP callers.

## Lifecycle

`voice.start` is an explicit session-start acknowledgement: it returns the
current state and session ID after permission checks and engine startup. It is
not speech recognition and it is not command completion. A recognized turn
gets a separate correlation ID and a `completed` or `failed` receipt. `voice.stop`
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

The command adapter submits a temporary ChatGPT thread through the existing
protected `chatgpt` interface and returns its verified submission response;
downstream answer delivery remains owned by that existing interface. A future
session owner can replace the injected adapter without changing the voice
contract.
