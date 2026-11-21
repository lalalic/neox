import Foundation

/// A conservative local energy gate for utterance boundaries. Energy alone is
/// never proof of a human barge-in: hosts must additionally reject their own
/// audible TTS before interrupting an assistant.
public struct VoiceActivityGate: Sendable {
    public enum Event: Sendable, Equatable { case started, ended }
    private let threshold: Float
    private let minimumSpeechMilliseconds: Double
    private let silenceMilliseconds: Double
    private var activeMilliseconds = 0.0
    private var quietMilliseconds = 0.0
    public private(set) var isSpeaking = false

    public init(threshold: Float = 0.024, minimumSpeechMilliseconds: Double = 90,
                silenceMilliseconds: Double = 1_100) {
        self.threshold = threshold
        self.minimumSpeechMilliseconds = minimumSpeechMilliseconds
        self.silenceMilliseconds = silenceMilliseconds
    }

    public mutating func consume(_ frame: AudioFrame) -> Event? {
        guard frame.sampleRate > 0, frame.channels > 0, frame.pcm16.count > 0,
              frame.pcm16.count % 2 == 0 else { return nil }
        let samples = frame.pcm16.withUnsafeBytes { raw -> Double in
            var sum = 0.0
            let values = raw.bindMemory(to: Int16.self)
            for value in values {
                let normalized = Double(Int16(littleEndian: value)) / 32768
                sum += normalized * normalized
            }
            return (sum / Double(values.count)).squareRoot()
        }
        let duration = Double(frame.pcm16.count / 2 / frame.channels) * 1000 / Double(frame.sampleRate)
        if samples >= Double(threshold) {
            quietMilliseconds = 0
            activeMilliseconds += duration
            if !isSpeaking && activeMilliseconds >= minimumSpeechMilliseconds {
                isSpeaking = true
                return .started
            }
        } else {
            activeMilliseconds = 0
            if isSpeaking {
                quietMilliseconds += duration
                if quietMilliseconds >= silenceMilliseconds {
                    isSpeaking = false
                    quietMilliseconds = 0
                    return .ended
                }
            }
        }
        return nil
    }

    public mutating func reset() {
        activeMilliseconds = 0
        quietMilliseconds = 0
        isSpeaking = false
    }
}
