import AVFoundation
import AppKit
import Speech
import SwiftUI

enum VoiceSessionState: String, Codable, Sendable {
    case idle, starting, listening, muted, stopping, completed, error
}

struct VoiceCommandReceipt: Codable, Sendable, Equatable {
    let sessionID: String
    let correlationID: String
    let status: String
    let text: String
    let result: String?
    let error: String?
}

struct VoiceCommandOutcome: Sendable {
    let status: String
    let result: String?

    static func completed(_ text: String) -> Self { .init(status: "completed", result: text) }
    static let submitted = Self(status: "submitted", result: nil)
}

protocol VoiceSynthesizer: AnyObject {
    func speak(_ text: String)
    func stop()
}

final class SystemVoiceSynthesizer: NSObject, VoiceSynthesizer {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil ? "zh-CN" : "en-US")
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

enum VoiceCommandRouting {
    static func isGatewayStatus(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["neo status", "neoy status", "neo 状态", "检查 neo 状态", "检查 neoy 状态"].contains(normalized)
    }
}

@MainActor
final class VoiceSessionController: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published private(set) var state: VoiceSessionState = .idle
    @Published private(set) var muted = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastReceipt: VoiceCommandReceipt?
    @Published private(set) var errorMessage: String?
    private(set) var sessionID: String?

    private let synthesizer: VoiceSynthesizer
    private var commandExecutor: @Sendable (String, String, String) async throws -> VoiceCommandOutcome
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var stopTask: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var didSubmitTurn = false
    private var finalResultReceived = false
    private var stopGeneration = 0
    private var recognitionGeneration = 0
    private var tapInstalled = false

    init(
        synthesizer: VoiceSynthesizer = SystemVoiceSynthesizer(),
        commandExecutor: @escaping @Sendable (String, String, String) async throws -> VoiceCommandOutcome = { _, _, text in .completed(text) }
    ) {
        self.synthesizer = synthesizer
        self.commandExecutor = commandExecutor
        super.init()
    }

    func setCommandExecutor(_ executor: @escaping @Sendable (String, String, String) async throws -> VoiceCommandOutcome) {
        commandExecutor = executor
    }

    func start(language: String = "en-US") async {
        guard state == .idle || state == .completed || state == .error else { return }
        state = .starting
        errorMessage = nil
        transcript = ""
        lastReceipt = nil
        muted = false
        didSubmitTurn = false
        finalResultReceived = false
        stopGeneration += 1
        recognitionGeneration += 1
        let recognitionID = recognitionGeneration
        let generation = stopGeneration
        let speechStatus = await requestSpeechAuthorization()
        guard state == .starting, generation == stopGeneration else { return }
        guard speechStatus == .authorized else {
            fail("Speech recognition permission is unavailable. Enable it in System Settings.")
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                fail("Microphone access was denied. Enable it in System Settings.")
                return
            }
        } else if micStatus != .authorized {
            fail("Microphone access is unavailable. Enable it in System Settings.")
            return
        }
        guard state == .starting, generation == stopGeneration else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            fail("Speech recognition is unavailable for \(language). Try en-US or zh-CN.")
            return
        }
        self.recognizer = recognizer
        recognizer.delegate = self
        let audioEngine = AVAudioEngine()
        let speechRequest = SFSpeechAudioBufferRecognitionRequest()
        speechRequest.shouldReportPartialResults = true
        self.engine = audioEngine
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            Task { @MainActor in
                guard let self, self.state == .listening, !self.muted else { return }
                self.request?.append(buffer)
            }
        }
        tapInstalled = true
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            removeInputTap()
            fail("Microphone could not start: \(error.localizedDescription)")
            return
        }
        self.request = speechRequest
        self.sessionID = UUID().uuidString
        self.state = .listening
        recognitionTask = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, recognitionID == self.recognitionGeneration else { return }
                if let result {
                    await self.acceptRecognition(text: result.bestTranscription.formattedString, isFinal: result.isFinal, generation: recognitionID)
                } else if let error, self.state == .listening {
                    self.fail("Speech recognition failed: \(error.localizedDescription)")
                }
            }
        }
        // A turn is bounded even after an explicit start; start again for another turn.
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    func stop() async {
        guard state == .starting || state == .listening || state == .muted else { return }
        state = .stopping
        stopGeneration += 1
        stopTask?.cancel()
        removeInputTap()
        engine?.stop()
        request?.endAudio()
        // After endAudio, Speech needs time to emit its final transcription.
        // A bounded grace period prevents losing the last words if it never does.
        for _ in 0..<20 where !finalResultReceived && !didSubmitTurn {
            try? await Task.sleep(for: .milliseconds(100))
        }
        await finishTurn()
    }

    func setMuted(_ value: Bool) {
        guard state == .listening || state == .muted else { return }
        muted = value
        state = value ? .muted : .listening
    }

    // Deterministic seam for lifecycle tests; production callers use start().
    var currentRecognitionGeneration: Int { recognitionGeneration }

    func beginTestingSession(id: String = "test-session") {
        sessionID = id
        recognitionGeneration += 1
        lastReceipt = nil
        transcript = ""
        errorMessage = nil
        didSubmitTurn = false
        finalResultReceived = false
        state = .listening
        muted = false
    }

    func inject(text: String) async -> VoiceCommandReceipt {
        if sessionID == nil { sessionID = UUID().uuidString }
        await submit(text: text)
        return lastReceipt ?? VoiceCommandReceipt(sessionID: sessionID!, correlationID: UUID().uuidString, status: "failed", text: text, result: nil, error: "no receipt")
    }

    func speak(_ text: String) {
        synthesizer.speak(text)
    }

    // A submitted ChatGPT turn is an acknowledgement only. Only a matching
    // completed response can be voiced, and duplicate callbacks are rejected.
    @discardableResult
    func completeSubmittedReply(sessionID: String, correlationID: String, answer: String) throws -> VoiceCommandReceipt {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceToolError.invalid("Completed voice answer must not be empty")
        }
        guard let receipt = lastReceipt,
              receipt.sessionID == sessionID,
              receipt.correlationID == correlationID,
              receipt.status == "submitted" else {
            throw VoiceToolError.invalid("No matching pending voice turn")
        }
        let completed = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                            status: "completed", text: receipt.text, result: answer, error: nil)
        lastReceipt = completed
        synthesizer.speak(answer)
        return completed
    }

    // Shared by native Speech callbacks and deterministic tests.
    func acceptRecognition(text: String, isFinal: Bool, generation: Int? = nil) async {
        guard generation == nil || generation == recognitionGeneration else { return }
        guard !didSubmitTurn, state == .listening || state == .muted || state == .stopping else { return }
        transcript = text
        if isFinal {
            finalResultReceived = true
            await finishTurn()
        }
    }

    // Both the Speech final callback and Stop converge here. Exactly one turn is sent.
    private func finishTurn() async {
        guard !didSubmitTurn else { return }
        didSubmitTurn = true
        stopTask?.cancel()
        let finalText = transcript
        removeInputTap()
        engine?.stop()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        engine = nil
        state = .completed
        await submit(text: finalText)
    }

    private func submit(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let sessionID else { return }
        let correlationID = UUID().uuidString
        // Register correlation before dispatch: the callback can arrive before the
        // command executor returns its submission acknowledgement.
        lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                          status: "submitted", text: text, result: nil, error: nil)
        do {
            let outcome = try await commandExecutor(sessionID, correlationID, text)
            guard outcome.status == "completed" || outcome.status == "submitted" else {
                throw VoiceToolError.invalid("Unknown command outcome: \(outcome.status)")
            }
            guard outcome.status != "completed" || (outcome.result?.isEmpty == false) else {
                throw VoiceToolError.invalid("Completed command has no answer")
            }
            // Never replace a callback's completed receipt with a late submitted ack.
            guard lastReceipt?.sessionID == sessionID,
                  lastReceipt?.correlationID == correlationID,
                  lastReceipt?.status == "submitted" else { return }
            lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID, status: outcome.status, text: text, result: outcome.result, error: nil)
            if outcome.status == "completed", let answer = outcome.result { synthesizer.speak(answer) }
        } catch {
            // A completed callback wins over a late transport error.
            guard lastReceipt?.sessionID == sessionID,
                  lastReceipt?.correlationID == correlationID,
                  lastReceipt?.status == "submitted" else { return }
            lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID, status: "failed", text: text, result: nil, error: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func removeInputTap() {
        guard tapInstalled else { return }
        tapInstalled = false
        engine?.inputNode.removeTap(onBus: 0)
    }

    private func fail(_ message: String) {
        recognitionGeneration += 1
        errorMessage = message
        state = .error
        removeInputTap()
        engine?.stop()
        recognitionTask?.cancel()
        stopTask?.cancel()
        stopGeneration += 1
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

enum VoiceSessionTools {
    @MainActor
    static func register(on server: MCPServer, controller: VoiceSessionController) {
        server.register(tools: [CommandTool.facade(
            name: "voice.session",
            description: "Start, stop, mute, inject text, inspect, or speak for the explicit single-speaker Neo Listen/Talk session.",
            commands: commands(controller: controller),
            commandName: CommandTool.stripPrefix("voice.")
        )], protected: true)
    }

    @MainActor
    private static func commands(controller: VoiceSessionController) -> [ToolDefinition] {
        var result: [ToolDefinition] = []
        result.append(
            ToolDefinition(name: "voice.start", description: "Request microphone and speech permissions, then start one bounded listening turn.", parameters: schema(["language": .object(["type": .string("string"), "default": .string("en-US")])])) { args in
                let language = string(args, "language") ?? "en-US"
                await controller.start(language: language)
                return await MainActor.run { status(controller) }
            })
        result.append(
            ToolDefinition(name: "voice.stop", description: "Stop microphone capture and recognition.", parameters: schema([:])) { _ in
                await controller.stop()
                return await MainActor.run { status(controller) }
            })
        result.append(
            ToolDefinition(name: "voice.mute", description: "Mute or unmute microphone buffers without ending the session.", parameters: schema(["muted": .object(["type": .string("boolean")])], required: ["muted"])) { args in
                guard let muted = bool(args, "muted") else { throw VoiceToolError.invalid("muted is required") }
                await MainActor.run { controller.setMuted(muted) }
                return await MainActor.run { status(controller) }
            })
        result.append(
            ToolDefinition(name: "voice.inject", description: "Deterministic no-microphone text turn using the same command and TTS completion path.", parameters: schema(["text": .object(["type": .string("string")])], required: ["text"])) { args in
                guard let text = string(args, "text") else { throw VoiceToolError.invalid("text is required") }
                return encode(await controller.inject(text: text))
            })
        result.append(
            ToolDefinition(name: "voice.complete", description: "Deliver the real completed answer for a pending, correlated voice turn; duplicate and stale replies are rejected.", parameters: schema([
                "session_id": .object(["type": .string("string")]),
                "correlation_id": .object(["type": .string("string")]),
                "answer": .object(["type": .string("string")]),
            ], required: ["session_id", "correlation_id", "answer"])) { args in
                guard let session = string(args, "session_id"), let correlation = string(args, "correlation_id"),
                      let answer = string(args, "answer") else { throw VoiceToolError.invalid("session_id, correlation_id and answer are required") }
                return try await MainActor.run {
                    let receipt = try controller.completeSubmittedReply(sessionID: session, correlationID: correlation, answer: answer)
                    return encode(receipt)
                }
            })
        result.append(
            ToolDefinition(name: "voice.speak", description: "Speak text through the selected macOS output device.", parameters: schema(["text": .object(["type": .string("string")])], required: ["text"])) { args in
                guard let text = string(args, "text") else { throw VoiceToolError.invalid("text is required") }
                await MainActor.run { controller.speak(text) }
                return encodeObject(["status": "submitted", "text": text])
            })
        result.append(
            ToolDefinition(name: "voice.status", description: "Return voice session state, transcript, and the latest typed command receipt.", parameters: schema([:])) { _ in await MainActor.run { status(controller) } }
        )
        return result
    }

    @MainActor
    private static func status(_ controller: VoiceSessionController) -> String {
        encodeObject([
            "state": controller.state.rawValue,
            "muted": controller.muted,
            "session_id": controller.sessionID ?? NSNull(),
            "transcript": controller.transcript,
            "error": controller.errorMessage ?? NSNull(),
            "last_receipt": controller.lastReceipt.map { receipt in
                (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))) ?? NSNull()
            } ?? NSNull(),
        ])
    }

    private static func string(_ args: JSONValue, _ key: String) -> String? {
        guard case .object(let object) = args, case .string(let value)? = object[key] else { return nil }
        return value
    }

    private static func bool(_ args: JSONValue, _ key: String) -> Bool? {
        guard case .object(let object) = args, case .bool(let value)? = object[key] else { return nil }
        return value
    }

    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    private static func encodeObject(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encode(_ receipt: VoiceCommandReceipt) -> String {
        guard let data = try? JSONEncoder().encode(receipt) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum VoiceToolError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let value) = self { return value }; return nil }
}

@MainActor
struct VoiceSessionView: View {
    @ObservedObject var controller: VoiceSessionController
    @State private var injectedText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listen & Talk").font(.title2)
            Label(controller.state.rawValue.capitalized, systemImage: controller.state == .listening ? "mic.fill" : "mic.slash")
                .foregroundStyle(controller.state == .error ? .red : .primary)
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
            Text(controller.transcript.isEmpty ? "No speech recognized yet." : controller.transcript)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Start") { Task { await controller.start() } }.disabled(controller.state == .listening || controller.state == .muted)
                Button("Stop") { Task { await controller.stop() } }.disabled(controller.state == .idle || controller.state == .completed)
                Button(controller.muted ? "Unmute" : "Mute") { controller.setMuted(!controller.muted) }.disabled(controller.state != .listening && controller.state != .muted)
            }
            HStack { TextField("Inject text without microphone", text: $injectedText); Button("Send") { let text = injectedText; injectedText = ""; Task { _ = await controller.inject(text: text) } }.disabled(injectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            if let receipt = controller.lastReceipt { Text("Command \(receipt.status) · \(receipt.correlationID)").font(.caption).foregroundStyle(.secondary) }
        }.padding(22).frame(width: 520)
    }
}
