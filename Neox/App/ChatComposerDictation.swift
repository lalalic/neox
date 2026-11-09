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

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var hasTap = false
    private var audioSessionActive = false
    private var session = UUID()

    func toggle() {
        if isRecording || isStarting {
            stop()
        } else {
            Task { await start() }
        }
    }

    private func start() async {
        guard !isStarting && !isRecording else { return }
        isStarting = true
        let token = UUID()
        session = token
        defer { isStarting = false }

        let speechAuthorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized, token == session else { return }
        let microphoneAuthorized = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard microphoneAuthorized, token == session else { return }

        let language = Locale.preferredLanguages.first ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)),
              recognizer.isAvailable else { return }

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
            guard format.sampleRate > 0 else { stop(); return }
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
                    if error != nil { self.stop() }
                }
            }
            try engine.start()
            guard token == session else { stop(); return }
            isRecording = true
        } catch {
            stop()
        }
    }

    func stop() {
        session = UUID() // Ignore callbacks from the previous recording.
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
