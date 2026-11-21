import Foundation

/// Raw interleaved little-endian signed PCM16. The audio-device owner performs
/// rate conversion before handing audio to a provider that needs another format.
public struct AudioFrame: Sendable, Equatable {
    public let pcm16: Data
    public let sampleRate: Int
    public let channels: Int

    public init(pcm16: Data, sampleRate: Int, channels: Int) {
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

public enum TranscriptEvent: Sendable, Equatable {
    case speechStarted
    case partial(String)
    case final(String)
    case speechEnded
}

/// Providers must never own the device's shared microphone or audio session.
/// They only consume audio supplied by the capture owner.
public protocol SpeechRecognitionProvider: Sendable {
    func transcribe(audio: AsyncThrowingStream<AudioFrame, Error>, language: String) -> AsyncThrowingStream<TranscriptEvent, Error>
}

/// Providers synthesize PCM without starting a private playback device.
public protocol SpeechSynthesisProvider: Sendable {
    func synthesize(_ text: String, language: String) -> AsyncThrowingStream<AudioFrame, Error>
}

/// The host owns the output device and may implement it with LiveKit or another
/// audio engine. `play` returns only after the supplied audio has been played.
public protocol SpeechAudioOutput: Sendable {
    func play(_ audio: AsyncThrowingStream<AudioFrame, Error>) async throws
    func stop() async
}

/// Generic upstream reply events; transport correlation and authorization stay
/// with the host application, not this package.
public enum VoiceReplyEvent: Sendable, Equatable {
    case text(sequence: Int, value: String)
    case completed
    case failed(String)
    case heartbeat
}

public enum SpeechQueueError: Error, Sendable, Equatable {
    case invalidSequence(expected: Int, received: Int)
    case conflictingReplay(sequence: Int)
    case emptyText
    case alreadyTerminal
    case cancelled
    case upstream(String)
}
