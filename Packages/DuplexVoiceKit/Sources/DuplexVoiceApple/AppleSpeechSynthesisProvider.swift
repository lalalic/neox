import AVFoundation
import DuplexVoiceKit
import Foundation

/// Uses device TTS `write` to deliver PCM data, not to play via a separate
/// synthesizer output route. All playback is owned by the host audio engine.
public struct AppleSpeechSynthesisProvider: SpeechSynthesisProvider {
    public init() {}

    public func synthesize(_ text: String, language: String)
        -> AsyncThrowingStream<AudioFrame, Error> {
        AsyncThrowingStream { continuation in
            let box = SynthesizerBox()
            let job = Task { @MainActor in
                box.start(text: text, language: language, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                job.cancel()
                Task { @MainActor in box.stop() }
            }
        }
    }

    fileprivate static func convertToPCM16(_ buffer: AVAudioPCMBuffer) throws -> AudioFrame {
        let format = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard frames > 0 && channels > 0 else { throw AppleSpeechError.invalidAudioFrame }
        var bytes = [Int16](repeating: 0, count: frames * channels)
        if let samples = buffer.floatChannelData {
            for f in 0..<frames {
                for c in 0..<channels {
                    let value = format.isInterleaved ? samples[0][f * channels + c] : samples[c][f]
                    bytes[f * channels + c] = Int16(max(-32768, min(32767, (value * 32767).rounded())))
                }
            }
        } else if let samples = buffer.int16ChannelData {
            for f in 0..<frames {
                for c in 0..<channels { bytes[f * channels + c] = format.isInterleaved ? samples[0][f * channels + c] : samples[c][f] }
            }
        } else {
            throw AppleSpeechError.invalidAudioFrame
        }
        return AudioFrame(pcm16: bytes.withUnsafeBytes { Data($0) },
                          sampleRate: Int(format.sampleRate), channels: channels)
    }
}

/// Serialized access to AVSpeechSynthesizer; only the actor-isolated API uses
/// this non-Sendable system object. The bridge itself transports no model data.
private final class SynthesizerBox: @unchecked Sendable {
    @MainActor private var synthesizer: AVSpeechSynthesizer?

    @MainActor func start(text: String, language: String,
                          continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation) {
        let value = AVSpeechSynthesizer()
        synthesizer = value
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        value.write(utterance, toBufferCallback: Self.audioHandler(continuation))
    }

    // AVSpeechSynthesizer can supply PCM buffers off the main actor. The
    // callback factory is nonisolated so Swift 6 never assumes main-executor
    // isolation while invoking it.
    private nonisolated static func audioHandler(
        _ continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation
    ) -> @Sendable (AVAudioBuffer) -> Void {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                continuation.finish(throwing: AppleSpeechError.invalidAudioFrame)
                return
            }
            guard pcm.frameLength > 0 else { continuation.finish(); return }
            do { continuation.yield(try AppleSpeechSynthesisProvider.convertToPCM16(pcm)) }
            catch { continuation.finish(throwing: error) }
        }
    }

    @MainActor func stop() {
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
    }
}
