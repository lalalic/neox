import AVFoundation
import Foundation
import Speech
import SwiftUI

/// Local microphone dictation for the Chat composer. Never submits messages:
/// the owner reviews recognized text and taps Send as usual.
@MainActor
final class ChatComposerDictation: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorText: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var hasTap = false
    private var audioSessionActive = false
    private var session = UUID()
    private var startupTask: Task<Void, Never>?
    private let speechPermission: @Sendable () async -> Bool
    private let microphonePermission: @Sendable () async -> Bool

    init(speechPermission: @escaping @Sendable () async -> Bool = {
        await ChatComposerDictation.requestSpeechPermission()
    }, microphonePermission: @escaping @Sendable () async -> Bool = {
        await ChatComposerDictation.requestMicrophonePermission()
    }) {
        self.speechPermission = speechPermission
        self.microphonePermission = microphonePermission
    }

    func toggle() {
        if isRecording || isStarting {
            stop()
        } else {
            // Set the latch before creating the Task so two fast taps cannot
            // enqueue two permission/audio startups on the main actor.
            isStarting = true
            startupTask?.cancel()
            startupTask = Task { [weak self] in await self?.start() }
        }
    }

    private func start() async {
        guard !Task.isCancelled, isStarting && !isRecording else { return }
        errorText = nil
        let token = UUID()
        session = token
        defer {
            if session == token {
                isStarting = false
                startupTask = nil
            }
        }

        let speechAuthorized = await speechPermission()
        guard !Task.isCancelled, token == session else { return }
        guard speechAuthorized else {
            fail("Speech Recognition permission is required.")
            return
        }
        let microphoneAuthorized = await microphonePermission()
        guard !Task.isCancelled, token == session else { return }
        guard microphoneAuthorized else {
            fail("Microphone permission is required.")
            return
        }

        let language = Locale.preferredLanguages.first ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else {
            fail("Speech recognition is unavailable for the selected language.")
            return
        }

        self.recognizer = recognizer
        let audioRequest = SFSpeechAudioBufferRecognitionRequest()
        audioRequest.shouldReportPartialResults = true
        audioRequest.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = audioRequest
        transcript = ""

        do {
            let sessionAudio = AVAudioSession.sharedInstance()
            try sessionAudio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try sessionAudio.setActive(true)
            audioSessionActive = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard Self.inputFormatIsUsable(sampleRate: format.sampleRate,
                                            channelCount: format.channelCount) else {
                fail("The microphone audio format is unavailable.")
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                audioRequest.append(buffer)
            }
            hasTap = true
            recognitionTask = recognizer.recognitionTask(with: audioRequest) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.session == token else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal { self.stop() }
                    }
                    if let error {
                        self.fail("Dictation unavailable: \(error.localizedDescription)")
                    }
                }
            }
            try engine.start()
            guard token == session else {
                stop()
                return
            }
            isRecording = true
        } catch {
            fail("Dictation unavailable: \(error.localizedDescription)")
        }
    }

    // Permission callbacks may run on a TCC/XPC queue. Keep their
    // continuations nonisolated so Swift 6 does not trap crossing actors.
    private nonisolated static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private nonisolated static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        errorText = message
    }

    static func inputFormatIsUsable(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }

    func stop() {
        session = UUID() // Ignore callbacks from the previous recording.
        startupTask?.cancel()
        startupTask = nil
        errorText = nil
        if engine.isRunning { engine.stop() }
        if hasTap {
            engine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        isRecording = false
        isStarting = false
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }
}
