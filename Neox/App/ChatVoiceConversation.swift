import AVFoundation
import Combine
import DuplexVoiceKit
import DuplexVoiceApple
import DuplexVoiceLiveKit
import Foundation
import Speech

struct ChatVoiceTurn: Equatable {
    let id: UUID
    let text: String
}

/// Foreground voice mode for Chat. The Chat tab owns its server transport and
/// durable history; this controller only handles local full-duplex audio.
/// Microphone input is always LiveKit-owned, with no LiveKit Server/Room.
@MainActor
final class ChatVoiceConversation: ObservableObject {
    enum Phase: String { case idle, starting, listening, thinking, speaking, stopped, error }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var assistantText = ""
    @Published private(set) var errorText: String?
    @Published private(set) var committedTurn: ChatVoiceTurn?

    private let capture = LiveKitLocalCapture()
    private let stt: any SpeechRecognitionProvider
    private let tts: any SpeechSynthesisProvider
    private let output: any SpeechAudioOutput
    private var gate = VoiceActivityGate()
    private var captureTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var audioInput: AsyncThrowingStream<AudioFrame, Error>.Continuation?
    private var recognitionGeneration = UUID()
    private var pendingRequestID: String?
    private var playback: SpeechQueue?
    private var generation = UUID()
    private var heardSpeech = false
    private var active = false

    init(stt: any SpeechRecognitionProvider = AppleSpeechRecognitionProvider(),
         tts: any SpeechSynthesisProvider = AppleSpeechSynthesisProvider(),
         output: any SpeechAudioOutput = LiveKitSpeechOutput()) {
        self.stt = stt
        self.tts = tts
        self.output = output
    }

    func start() async {
        guard !active else { return }
        phase = .starting
        errorText = nil
        let token = UUID()
        generation = token
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard generation == token else { return }
        let microphoneAllowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard generation == token else { return }
        guard speechAllowed && microphoneAllowed else {
            phase = .error
            errorText = "Microphone and Speech Recognition permission are required."
            return
        }
        do {
            let audio = try capture.start()
            active = true
            gate.reset()
            startRecognition()
            phase = .listening
            captureTask = Task { [weak self] in
                do {
                    for try await frame in audio {
                        guard let self, self.active, self.generation == token else { return }
                        self.audioInput?.yield(frame)
                        self.handleAudio(frame)
                    }
                    guard let self, self.generation == token, self.active else { return }
                    self.stop()
                    self.errorText = "Microphone stream ended unexpectedly."
                    self.phase = .error
                } catch {
                    guard let self, self.generation == token else { return }
                    self.stop()
                    self.errorText = "Microphone audio stopped: \(error.localizedDescription)"
                    self.phase = .error
                }
            }
        } catch {
            phase = .error
            errorText = "Cannot start LiveKit microphone: \(error.localizedDescription)"
        }
    }

    func stop() {
        generation = UUID()
        let wasActive = active
        active = false
        recognitionTask?.cancel()
        recognitionTask = nil
        commitTask?.cancel()
        commitTask = nil
        audioInput?.finish()
        audioInput = nil
        captureTask?.cancel()
        captureTask = nil
        let oldPlayback = playback
        playback = nil
        pendingRequestID = nil
        if wasActive { try? capture.stop() }
        Task { await oldPlayback?.interrupt(); await output.stop() }
        gate.reset()
        heardSpeech = false
        transcript = ""
        phase = .stopped
    }

    private func startRecognition() {
        recognitionTask?.cancel()
        audioInput?.finish()
        let token = UUID()
        recognitionGeneration = token
        let audio = AsyncThrowingStream<AudioFrame, Error>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            self.audioInput = continuation
        }
        recognitionTask = Task { [weak self, stt] in
            let locale = Locale.preferredLanguages.first ?? "en-US"
            do {
                for try await event in stt.transcribe(audio: audio, language: locale) {
                    guard let self, self.active, self.recognitionGeneration == token else { return }
                    switch event {
                    case let .partial(text), let .final(text):
                        self.handleTranscript(text)
                    case .speechStarted, .speechEnded: break
                    }
                }
                guard let self, self.active, self.recognitionGeneration == token else { return }
                self.startRecognition() // Rotate system recognizer on normal finalization.
            } catch {
                guard let self, self.active, self.recognitionGeneration == token else { return }
                if case AppleSpeechError.recognizerUnavailable = error {
                    self.stop()
                    self.errorText = "Speech recognizer unavailable for the selected language."
                    self.phase = .error
                    return
                }
                // Don't spin if the Speech framework is temporarily failing.
                try? await Task.sleep(for: .milliseconds(800))
                guard self.active, self.recognitionGeneration == token else { return }
                self.startRecognition()
            }
        }
    }

    private func handleTranscript(_ value: String) {
        guard active, !value.isEmpty else { return }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if phase == .speaking, !assistantText.isEmpty,
           assistantText.localizedCaseInsensitiveContains(text) {
            return // Don't treat our own echoed TTS as a user interruption.
        }
        transcript = text
        heardSpeech = true
        if phase == .speaking {
            interruptReply()
        }
    }

    private func handleAudio(_ frame: AudioFrame) {
        guard let event = gate.consume(frame) else { return }
        switch event {
        case .started:
            commitTask?.cancel()
            commitTask = nil
            // Energy is not enough to interrupt playback; Apple STT must
            // recognize speech that is distinct from our TTS.
            if phase != .speaking { phase = .listening }
        case .ended:
            // Very short utterances can be transcribed after VAD detects
            // silence. Keep feeding STT briefly rather than dropping words.
            let token = recognitionGeneration
            commitTask?.cancel()
            commitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, self.active,
                      self.recognitionGeneration == token, !self.gate.isSpeaking else { return }
                self.finishUtterance()
            }
        }
    }

    private func finishUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard heardSpeech, !text.isEmpty, text.count <= 2000 else {
            heardSpeech = false
            transcript = ""
            return
        }
        // Ignore late recognition results from the completed turn.
        heardSpeech = false
        transcript = ""
        recognitionGeneration = UUID()
        audioInput?.finish()
        recognitionTask?.cancel()
        recognitionTask = nil
        startRecognition()
        if phase == .speaking { interruptReply() }
        assistantText = ""
        phase = .thinking
        committedTurn = ChatVoiceTurn(id: UUID(), text: text)
    }

    /// Bound to the exact locally-enqueued Chat request. A response from an
    /// unrelated request or the previous interrupted turn must not play.
    func expectReply(requestID: String) {
        pendingRequestID = requestID
    }

    func receive(_ item: ChatGatewayItem) {
        guard active, let requestID = pendingRequestID,
              item.id == "report:" + requestID else { return }
        let terminal = ["completed", "failed"].contains(item.status ?? "")
        guard terminal else { return } // Do not speak "Processing..." placeholders.
        pendingRequestID = nil
        if item.status == "failed" {
            phase = .listening
            errorText = "The assistant could not complete that reply."
            return
        }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .listening; return }
        assistantText = text
        let language = text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) })
            ? "zh-CN" : (Locale.preferredLanguages.first ?? "en-US")
        let queue = SpeechQueue(synthesis: tts, output: output, language: language)
        playback = queue
        phase = .speaking
        let token = generation
        Task { [weak self] in
            do {
                try await queue.accept(sequence: 1, text: text)
                try await queue.complete()
                guard let self, self.active, self.generation == token,
                      self.playback === queue else { return }
                self.playback = nil
                self.phase = .listening
            } catch {
                guard let self, self.active, self.generation == token,
                      self.playback === queue else { return }
                self.playback = nil
                self.errorText = "Speech playback unavailable: \(error.localizedDescription)"
                self.phase = .listening
            }
        }
    }

    func receiveFailure(requestID: String) {
        guard active, pendingRequestID == requestID else { return }
        pendingRequestID = nil
        phase = .listening
        errorText = "The assistant could not complete that reply."
    }

    func interruptReply() {
        let old = playback
        playback = nil
        pendingRequestID = nil
        Task { await old?.interrupt() }
        if active { phase = .listening }
    }
}
