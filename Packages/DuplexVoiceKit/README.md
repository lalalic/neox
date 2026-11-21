# DuplexVoiceKit

Reusable Swift Package for bidirectional speech applications. No product, model,
server, or transport assumptions in the core module.

## Modules and current implementation

- Pluggable `SpeechRecognitionProvider` (PCM16 audio -> transcription events)
- Pluggable `SpeechSynthesisProvider` (text -> streaming PCM16 audio)
- `DuplexVoiceApple`: on-device `SFSpeechRecognizer` STT and
  `AVSpeechSynthesizer.write` PCM TTS (built; device behavior not yet validated)
- `DuplexVoiceLiveKit`: LiveKit 2.19 local PCM capture with Voice Processing,
  without a Room or server (macOS package build verified)
- Host-owned `SpeechAudioOutput` for the streaming LiveKit playback adapter
- Stateful sentence merging and strict FIFO TTS queue
- Duplicate replay and sequence checks, explicit completion after playback,
  interruption, cancellation, and failure signaling
- `VoiceConversation` adapter accepting generic reply events

## Audio ownership

Use LiveKit Swift SDK's local audio mode for audio capture / Voice Processing.
No LiveKit Server is needed for local capture. LiveKit's exposed
`AudioManager.startLocalRecording(...)` and capture callback should be bridged
into `AudioFrame` without a second microphone owner. Audio output must be tested
for AEC reference signal fidelity; Apple TTS playing through a separate engine
is **not** sufficient proof of full duplex.

The core does **not** embed the LiveKit runtime, a cloud service, SwiftUI,
or an ElevenLabs Agent protocol. LiveKit and Apple providers are separate
opt-in library products. A streaming LiveKit `SpeechAudioOutput` implementation,
VAD, and real-device audio-loop tests are still required before full duplex can
be claimed. This initial package is not a production voice SDK.

## Integration contract

```swift
import DuplexVoiceKit

let output: any SpeechAudioOutput = MyLiveKitOutput()
let tts: any SpeechSynthesisProvider = MySpeechProvider()
let queue = SpeechQueue(synthesis: tts, output: output, language: "zh-CN")
let conversation = VoiceConversation(playback: queue)
try await conversation.receive(.text(sequence: 1, value: "你好，"))
try await conversation.receive(.text(sequence: 2, value: "有什么可以帮你？"))
try await conversation.receive(.completed)
// call await conversation.userStartedSpeaking() when live VAD detects a barge-in
```

Providers never open their own microphone, start a second sound output engine,
or own the device audio session. Hosts own credentials, model requests, stream
reconnect, and request IDs. Nothing in the package requires any particular
backend or event system.

## Build and remaining device gates

`swift test`

The full package resolves LiveKit 2.19.0 as a SwiftPM dependency. To use the
components independently, add the respective library products to your app.
Never instantiate competing audio-device owners in the same app.

Before production: implement a LiveKit-owned streaming audio sink, validate
AEC against the actual TTS playback reference, verify VAD barge-in and Chinese
transcription on a physical iPhone, and test Bluetooth routing, interruptions,
STT/TTS provider fallback and cancellation races.
