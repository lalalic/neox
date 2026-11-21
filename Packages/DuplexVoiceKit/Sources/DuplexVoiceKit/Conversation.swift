import Foundation

/// A transport-independent coordinator for one conversational turn. Speech
/// detection is supplied by the active STT/VAD provider, not fabricated here.
public actor VoiceConversation {
    private let playback: SpeechQueue
    private var interrupted = false

    public init(playback: SpeechQueue) { self.playback = playback }

    public func receive(_ event: VoiceReplyEvent) async throws {
        guard !interrupted else { return }
        switch event {
        case let .text(sequence, value): try await playback.accept(sequence: sequence, text: value)
        case .completed: try await playback.complete()
        case let .failed(reason): await playback.fail(reason)
        case .heartbeat: break
        }
    }

    public func userStartedSpeaking() async {
        interrupted = true
        await playback.interrupt()
    }
}
