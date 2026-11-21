import AVFoundation
import DuplexVoiceKit
import Foundation
import Speech

/// Apple's speech recognizer consumes PCM supplied by the host audio capture
/// path. The caller owns microphone permission, LiveKit, and the AVAudioSession.
public struct AppleSpeechRecognitionProvider: SpeechRecognitionProvider {
    public init() {}

    public func transcribe(audio: AsyncThrowingStream<AudioFrame, Error>, language: String)
        -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let job = Task { @MainActor in
                guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
                      recognizer.isAvailable else {
                    continuation.finish(throwing: AppleSpeechError.recognizerUnavailable)
                    return
                }
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
                let recognition = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        continuation.yield(result.isFinal
                            ? .final(result.bestTranscription.formattedString)
                            : .partial(result.bestTranscription.formattedString))
                        if result.isFinal { continuation.yield(.speechEnded); continuation.finish() }
                    } else if let error {
                        continuation.finish(throwing: error)
                    }
                }
                // speechStarted must come from an actual VAD detection, not recognition startup.
                do {
                    for try await frame in audio {
                        try Task.checkCancellation()
                        guard frame.channels > 0, frame.sampleRate > 0,
                              frame.pcm16.count % (2 * frame.channels) == 0,
                              let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                         sampleRate: Double(frame.sampleRate),
                                                         channels: AVAudioChannelCount(frame.channels),
                                                         interleaved: true),
                              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                            frameCapacity: AVAudioFrameCount(frame.pcm16.count / (2 * frame.channels))),
                              let samples = buffer.int16ChannelData?.pointee else {
                            throw AppleSpeechError.invalidAudioFrame
                        }
                        frame.pcm16.withUnsafeBytes { source in
                            if let base = source.baseAddress { memcpy(samples, base, frame.pcm16.count) }
                        }
                        buffer.frameLength = buffer.frameCapacity
                        request.append(buffer)
                    }
                    request.endAudio()
                } catch {
                    request.endAudio()
                    continuation.finish(throwing: error)
                }
                // recognitionTask will deliver a final transcript after audio ends.
                // Cancellation is also required for a session that stops prematurely.
                if Task.isCancelled { recognition.cancel() }
            }
            continuation.onTermination = { @Sendable _ in job.cancel() }
        }
    }
}

public enum AppleSpeechError: Error, Sendable {
    case recognizerUnavailable
    case invalidAudioFrame
}
