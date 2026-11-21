import AVFoundation
import DuplexVoiceKit
import Foundation
import LiveKit

public enum LiveKitSpeechOutputError: Error {
    case inconsistentAudioFormat
    case emptyAudio
}

/// Local device playback using LiveKit's SoundPlayer. A file-backed phrase is
/// required because SoundPlayer.prepare accepts file URLs, not streaming PCM.
/// Queue/Merge stays in DuplexVoiceKit, so one phrase is synthesized and played
/// at a time. No Room or LiveKit Server is involved.
public actor LiveKitSpeechOutput: SpeechAudioOutput {
    private var current: SoundHandle?
    private var generation: UInt64 = 0

    public init() {}

    public func play(_ audio: AsyncThrowingStream<AudioFrame, Error>) async throws {
        let token = generation
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplex-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: path) }
        var file: AVAudioFile?
        var count = 0
        for try await frame in audio {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            guard frame.sampleRate > 0, frame.channels > 0,
                  !frame.pcm16.isEmpty, frame.pcm16.count % (2 * frame.channels) == 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: Double(frame.sampleRate),
                      channels: AVAudioChannelCount(frame.channels), interleaved: true),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                      frameCapacity: AVAudioFrameCount(frame.pcm16.count / (2 * frame.channels))),
                  let destination = buffer.int16ChannelData?.pointee else {
                throw LiveKitSpeechOutputError.inconsistentAudioFormat
            }
            if file == nil {
                file = try AVAudioFile(forWriting: path, settings: format.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            } else if file?.fileFormat.sampleRate != Double(frame.sampleRate) ||
                        file?.fileFormat.channelCount != AVAudioChannelCount(frame.channels) {
                throw LiveKitSpeechOutputError.inconsistentAudioFormat
            }
            frame.pcm16.withUnsafeBytes { src in
                if let address = src.baseAddress { memcpy(destination, address, frame.pcm16.count) }
            }
            buffer.frameLength = buffer.frameCapacity
            try file?.write(from: buffer)
            count += Int(buffer.frameLength)
        }
        guard count > 0 else { throw LiveKitSpeechOutputError.emptyAudio }
        file = nil // Flush the WAV header before LiveKit reads the file.
        guard token == generation else { throw CancellationError() }
        let handle = try await SoundPlayer.shared.prepare(fileURL: path)
        current = handle
        defer { current = nil }
        defer { Task { await handle.release() } }
        guard token == generation else { throw CancellationError() }
        try await handle.play(options: SoundPlaybackOptions(destination: .local))
        while await handle.isPlaying(destination: .local) {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public func stop() async {
        generation &+= 1
        if let current { await current.stop(destination: .local) }
        current = nil
    }
}
