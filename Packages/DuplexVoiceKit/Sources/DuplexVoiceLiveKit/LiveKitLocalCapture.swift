import DuplexVoiceKit
import Foundation
import LiveKit

public enum LiveKitCaptureError: Error {
    case captureAlreadyActive
    case anotherAudioProcessorActive
}

/// Observes post-processed microphone frames from LiveKit's device engine.
/// Runs entirely locally without a Room or a LiveKit Server. Permission must
/// be requested by the host before starting this source.
///
/// The LiveKit process-wide AudioManager supports one processing delegate.
/// This owner intentionally fails rather than overwrite another consumer.
public final class LiveKitLocalCapture: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    private var sampleRate = 48_000

    public override init() { super.init() }

    @MainActor
    public func start() throws -> AsyncThrowingStream<AudioFrame, Error> {
        lock.lock()
        let active = continuation != nil
        lock.unlock()
        guard !active else { throw LiveKitCaptureError.captureAlreadyActive }
        let manager = AudioManager.shared
        guard manager.capturePostProcessingDelegate == nil else {
            throw LiveKitCaptureError.anotherAudioProcessorActive
        }
        let stream = AsyncThrowingStream<AudioFrame, Error>(bufferingPolicy: .bufferingNewest(60)) { observer in
            lock.lock()
            continuation = observer
            lock.unlock()
        }
        manager.capturePostProcessingDelegate = self
        do {
            try manager.startLocalRecording(audioProcessingOptions: .init())
        } catch {
            manager.capturePostProcessingDelegate = nil
            lock.lock()
            continuation?.finish(throwing: error)
            continuation = nil
            lock.unlock()
            throw error
        }
        return stream
    }

    @MainActor
    public func stop() throws {
        let manager = AudioManager.shared
        defer {
            if manager.capturePostProcessingDelegate === self {
                manager.capturePostProcessingDelegate = nil
            }
            lock.lock()
            continuation?.finish()
            continuation = nil
            lock.unlock()
        }
        try manager.stopLocalRecording()
    }

    public func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        lock.lock()
        sampleRate = sampleRateHz
        lock.unlock()
    }

    public func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        // Audio samples are provided by the LiveKit processing callback as
        // Int16-valued Float slots. Copy them before the callback returns.
        let frames = audioBuffer.frames
        let channels = audioBuffer.channels
        guard frames > 0 && channels > 0 else { return }
        var samples = [Int16](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let source = audioBuffer.rawBuffer(forChannel: channel)
            for index in 0..<frames {
                samples[index * channels + channel] = Int16(max(-32768, min(32767, source[index].rounded())))
            }
        }
        lock.lock()
        let observer = continuation
        let rate = sampleRate
        lock.unlock()
        observer?.yield(AudioFrame(pcm16: samples.withUnsafeBytes { Data($0) },
                                   sampleRate: rate, channels: channels))
    }

    public func audioProcessingRelease() {}
}
