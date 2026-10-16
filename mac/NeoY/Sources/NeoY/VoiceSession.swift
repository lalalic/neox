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

@MainActor
final class VoiceSessionController: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published private(set) var state: VoiceSessionState = .idle
    @Published private(set) var muted = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastReceipt: VoiceCommandReceipt?
    @Published private(set) var errorMessage: String?
    private(set) var sessionID: String?

    private let synthesizer: VoiceSynthesizer
    private var commandExecutor: @Sendable (String, String, String) async throws -> String
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var stopTask: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?

    init(
        synthesizer: VoiceSynthesizer = SystemVoiceSynthesizer(),
        commandExecutor: @escaping @Sendable (String, String, String) async throws -> String = { _, _, text in text }
    ) {
        self.synthesizer = synthesizer
        self.commandExecutor = commandExecutor
        super.init()
    }

    func setCommandExecutor(_ executor: @escaping @Sendable (String, String, String) async throws -> String) {
        commandExecutor = executor
    }

    func start(language: String = "en-US") async {
        guard state == .idle || state == .completed || state == .error else { return }
        state = .starting
        errorMessage = nil
        transcript = ""
        let speechStatus = await requestSpeechAuthorization()
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
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            fail("Speech recognition is unavailable for \(language). Try en-US or zh-CN.")
            return
        }
        self.recognizer = recognizer
        recognizer.delegate = self
        let audioEngine = AVAudioEngine()
        let speechRequest = SFSpeechAudioBufferRecognitionRequest()
        speechRequest.shouldReportPartialResults = true
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            Task { @MainActor in
                guard let self, self.state == .listening, !self.muted else { return }
                self.request?.append(buffer)
            }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("Microphone could not start: \(error.localizedDescription)")
            return
        }
        self.engine = audioEngine
        self.request = speechRequest
        self.sessionID = UUID().uuidString
        self.state = .listening
        recognitionTask = recognizer.recognitionTask(with: speechRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal { await self.submit(text: self.transcript) }
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
        stopTask?.cancel()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        engine = nil
        state = .completed
    }

    func setMuted(_ value: Bool) {
        guard state == .listening || state == .muted else { return }
        muted = value
        state = value ? .muted : .listening
    }

    // Deterministic seam for lifecycle tests; production callers use start().
    func beginTestingSession(id: String = "test-session") {
        sessionID = id
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

    private func submit(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let sessionID else { return }
        let correlationID = UUID().uuidString
        do {
            let result = try await commandExecutor(sessionID, correlationID, text)
            lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID, status: "completed", text: text, result: result, error: nil)
            synthesizer.speak(result)
        } catch {
            lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID, status: "failed", text: text, result: nil, error: error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        state = .error
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        recognitionTask?.cancel()
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
            description: "Start, stop, mute, inject text, inspect, or speak for the explicit single-speaker NeoY Listen/Talk session.",
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
