import AVFoundation
import AppKit
import Speech
import SwiftUI

struct VoiceThreadBinding: Codable, Equatable, Sendable {
    let threadID: String
    let projectID: String?

    static let storageKey = "neo.voice.threadBinding"
    var displayValue: String {
        guard let projectID else { return threadID }
        return "https://chatgpt.com/g/\(projectID)/c/\(threadID)"
    }

    static func parse(_ input: String) -> Self? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URLComponents(string: value), let host = url.host {
            guard url.scheme?.lowercased() == "https",
                  ["chatgpt.com", "www.chatgpt.com"].contains(host.lowercased()) else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard let index = parts.firstIndex(of: "c"), index + 1 < parts.count,
                  UUID(uuidString: parts[index + 1]) != nil else { return nil }
            let project = parts.firstIndex(of: "g").flatMap { i in
                i + 1 < parts.count && parts[i + 1].hasPrefix("g-p-") ? parts[i + 1] : nil
            }
            return Self(threadID: parts[index + 1], projectID: project)
        }
        guard UUID(uuidString: value) != nil else { return nil }
        return Self(threadID: value, projectID: nil)
    }

    static func load(defaults: UserDefaults = .standard) -> Self? {
        if let data = defaults.data(forKey: storageKey) {
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        guard let previous = defaults.string(forKey: storageKey) else { return nil }
        return parse(previous)
    }

    static func save(_ input: String, defaults: UserDefaults = .standard) -> Bool {
        guard let binding = parse(input), let data = try? JSONEncoder().encode(binding) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }
}

struct VoiceChatGPTTab: Sendable {
    let binding: VoiceThreadBinding
    let title: String

    static func parse(_ output: String) -> Self? {
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let url = lines.first, let binding = VoiceThreadBinding.parse(String(url)) else { return nil }
        let title = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return Self(binding: binding, title: title.isEmpty ? "ChatGPT Thread" : title)
    }

    static func readActive() -> Self? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Google Chrome\" to get (URL of active tab of front window) & linefeed & (title of active tab of front window)"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + 4) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

@MainActor
final class VoiceThreadSelection: ObservableObject {
    @Published private(set) var input = VoiceThreadBinding.load()?.displayValue ?? ""
    @Published private(set) var title = ""
    @Published private(set) var message = ""
    private var revision = 0

    func refreshFromChrome() {
        revision += 1
        let request = revision
        message = "Looking for the active ChatGPT tab…"
        Task.detached(priority: .userInitiated) {
            let tab = VoiceChatGPTTab.readActive()
            await MainActor.run {
                guard self.revision == request else { return }
                guard let tab else {
                    self.message = "No active ChatGPT tab in Chrome. The saved binding is unchanged."
                    return
                }
                let value = tab.binding.displayValue
                guard VoiceThreadBinding.save(value) else { return }
                self.input = value
                self.title = tab.title
                self.message = "Bound to Chrome's active ChatGPT tab."
            }
        }
    }
}

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
    var sequence: Int? = nil
    var final: Bool? = nil
    var deliveryStatus: String? = nil
}

struct VoiceCommandOutcome: Sendable {
    let status: String
    let result: String?

    static func completed(_ text: String) -> Self { .init(status: "completed", result: text) }
    static let submitted = Self(status: "submitted", result: nil)
}

@MainActor
protocol VoiceSynthesizer: AnyObject {
    func speak(_ text: String, completion: @escaping (Bool) -> Void)
    func stop()
}

@MainActor
final class SystemVoiceSynthesizer: NSObject, VoiceSynthesizer {
    private let synthesizer = AVSpeechSynthesizer()
    private var completions: [ObjectIdentifier: (Bool) -> Void] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, completion: @escaping (Bool) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) != nil ? "zh-CN" : "en-US")
        completions[ObjectIdentifier(utterance)] = completion
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

extension SystemVoiceSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(identifier, delivered: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(identifier, delivered: false) }
    }

    private func complete(_ identifier: ObjectIdentifier, delivered: Bool) {
        completions.removeValue(forKey: identifier)?(delivered)
    }
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
    private struct ReplySegment: Equatable {
        let text: String
        let final: Bool
        let receipt: VoiceCommandReceipt
    }
    private struct ReplyState {
        let sessionID: String
        let correlationID: String
        var nextSequence = 0
        var segments: [Int: ReplySegment] = [:]
        var finished = false
        var isDelivering = false
    }
    private var replyState: ReplyState?

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
        replyState = nil
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
        replyState = nil
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
        synthesizer.speak(text) { _ in }
    }

    // Bind delivery to the active session and its pending turn. The caller
    // cannot select a room, device, or other destination.
    @discardableResult
    func completeSubmittedReply(sessionID: String, correlationID: String, answer: String) async throws -> VoiceCommandReceipt {
        try await reply(sessionID: sessionID, correlationID: correlationID, sequence: 0, text: answer, final: true)
    }

    func reply(sessionID: String, correlationID: String, sequence: Int, text: String, final: Bool) async throws -> VoiceCommandReceipt {
        let clean = text
        guard (0...255).contains(sequence), clean.utf8.count <= 12_000,
              !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceToolError.invalid("sequence must be 0...255 and text must contain 1...12000 UTF-8 bytes")
        }
        guard sessionID == self.sessionID else { throw VoiceToolError.invalid("No active voice session matches session_id") }
        if replyState == nil {
            guard sequence == 0, let pending = lastReceipt,
                  pending.sessionID == sessionID, pending.correlationID == correlationID,
                  pending.status == "submitted" else {
                throw VoiceToolError.invalid("No matching pending voice turn")
            }
            replyState = ReplyState(sessionID: sessionID, correlationID: correlationID)
        }
        guard var state = replyState,
              state.sessionID == sessionID, state.correlationID == correlationID else {
            throw VoiceToolError.invalid("No matching pending voice turn")
        }
        if sequence < state.nextSequence {
            guard let previous = state.segments[sequence], previous.text == clean, previous.final == final else {
                throw VoiceToolError.invalid("Conflicting or stale voice reply segment")
            }
            return previous.receipt
        }
        guard !state.finished, !state.isDelivering, sequence == state.nextSequence else {
            throw VoiceToolError.invalid("Expected voice reply sequence \(state.nextSequence)")
        }

        let inbound = lastReceipt!
        // Reserve before suspension so concurrent calls cannot enqueue a
        // duplicate segment while the prior utterance is being played.
        state.nextSequence += 1
        state.isDelivering = true
        let delivering = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                             status: "delivering", text: inbound.text, result: nil,
                                             error: nil, sequence: sequence, final: final)
        state.segments[sequence] = ReplySegment(text: clean, final: final, receipt: delivering)
        replyState = state
        guard await speakAndWait(clean) else {
            guard var current = replyState, current.correlationID == correlationID else {
                throw VoiceToolError.invalid("Voice reply is no longer active")
            }
            let cancelled = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                                status: "cancelled", text: inbound.text, result: nil,
                                                error: "audio delivery cancelled", sequence: sequence, final: final,
                                                deliveryStatus: "cancelled")
            current.segments[sequence] = ReplySegment(text: clean, final: final, receipt: cancelled)
            current.isDelivering = false
            current.finished = true
            replyState = current
            return cancelled
        }

        guard var current = replyState, current.correlationID == correlationID,
              lastReceipt?.correlationID == correlationID else {
            throw VoiceToolError.invalid("Voice reply is no longer active")
        }
        let deliveredText = (0..<sequence).compactMap { current.segments[$0]?.text } + [clean]
        let receipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                          status: final ? "completed" : "delivered", text: inbound.text,
                                          result: final ? deliveredText.joined() : clean, error: nil,
                                          sequence: sequence, final: final, deliveryStatus: "delivered")
        current.segments[sequence] = ReplySegment(text: clean, final: final, receipt: receipt)
        current.isDelivering = false
        current.finished = final
        replyState = current
        if final { lastReceipt = receipt }
        return receipt
    }

    // Playback cancellation leaves any submitted command/tool task running.
    func cancelAudio() {
        synthesizer.stop()
    }

    private func speakAndWait(_ text: String) async -> Bool {
        await withCheckedContinuation { continuation in
            synthesizer.speak(text) { delivered in continuation.resume(returning: delivered) }
        }
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
        replyState = nil
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
            if outcome.status == "completed", let answer = outcome.result {
                lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                                  status: "delivering", text: text, result: nil, error: nil)
                let delivered = await speakAndWait(answer)
                guard lastReceipt?.sessionID == sessionID, lastReceipt?.correlationID == correlationID,
                      lastReceipt?.status == "delivering" else { return }
                lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                                  status: "completed", text: text, result: answer,
                                                  error: nil, deliveryStatus: delivered ? "delivered" : "cancelled")
            } else {
                lastReceipt = VoiceCommandReceipt(sessionID: sessionID, correlationID: correlationID,
                                                  status: "submitted", text: text, result: nil, error: nil)
            }
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
        // Listening and session controls belong to the native UI.
        // Agents can only deliver correlated replies.
        if let reply = commands(controller: controller).first(where: { $0.name == "voice.reply" }) {
            server.register(tools: [reply], protected: true)
        }
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
            ToolDefinition(name: "voice.complete", description: "Deliver one final answer for a pending, correlated voice turn; duplicate and stale replies are rejected.", parameters: schema([
                "session_id": .object(["type": .string("string")]),
                "correlation_id": .object(["type": .string("string")]),
                "answer": .object(["type": .string("string")]),
            ], required: ["session_id", "correlation_id", "answer"])) { args in
                guard let session = string(args, "session_id"), let correlation = string(args, "correlation_id"),
                      let answer = string(args, "answer") else { throw VoiceToolError.invalid("session_id, correlation_id and answer are required") }
                return encode(try await controller.completeSubmittedReply(sessionID: session, correlationID: correlation, answer: answer))
            })

        result.append(
            ToolDefinition(name: "voice.reply", description: "Queue text for speech on the Neo Mac. Available without an active microphone session.", parameters: schema([
                "text": .object(["type": .string("string"), "minLength": .int(1), "maxLength": .int(12_000)]),
            ], required: ["text"])) { args in
                guard let text = string(args, "text"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf8.count <= 12_000 else {
                    throw VoiceToolError.invalid("text must contain 1...12000 UTF-8 bytes")
                }
                await MainActor.run { controller.speak(text) }
                return encodeObject(["status": "queued"])
            })

        result.append(
            ToolDefinition(name: "voice.cancel_audio", description: "Stop voice playback without cancelling submitted command or tool work.", parameters: schema([:])) { _ in
                await MainActor.run { controller.cancelAudio() }
                return encodeObject(["status": "cancelled"])
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

    private static func integer(_ args: JSONValue, _ key: String) -> Int? {
        guard case .object(let object) = args else { return nil }
        if case .int(let value)? = object[key] { return value >= 0 ? value : nil }
        if case .double(let value)? = object[key], value >= 0, value.rounded(.towardZero) == value { return Int(exactly: value) }
        return nil
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
    @ObservedObject var selection: VoiceThreadSelection
    @State private var injectedText = ""
    @AppStorage("neo.voice.replyEnabled") private var voiceReplyEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Listen & Talk").font(.title2)
            if !selection.title.isEmpty {
                Text(selection.title).font(.headline).lineLimit(2)
                Text("ChatGPT · \(VoiceThreadBinding.load()?.threadID ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(selection.input.isEmpty ? "No ChatGPT thread selected" : selection.input)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Refresh") { selection.refreshFromChrome() }
                    .disabled(![VoiceSessionState.idle, .completed, .error].contains(controller.state))
            }
            if !selection.message.isEmpty {
                Text(selection.message).font(.caption).foregroundStyle(.secondary)
            }
            Text(VoiceThreadBinding.load() == nil ? "Open a ChatGPT tab in Chrome, then Refresh." : "Speech is sent to the selected thread.").font(.caption).foregroundStyle(.secondary)
            Toggle("Voice Reply", isOn: $voiceReplyEnabled)
            Label(controller.state.rawValue.capitalized, systemImage: controller.state == .listening ? "mic.fill" : "mic.slash")
                .foregroundStyle(controller.state == .error ? .red : .primary)
            if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
            Text(controller.transcript.isEmpty ? "No speech recognized yet." : controller.transcript)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Start") { Task { await controller.start() } }.disabled(VoiceThreadBinding.load() == nil || controller.state == .listening || controller.state == .muted)
                Button("Stop") { Task { await controller.stop() } }.disabled(controller.state == .idle || controller.state == .completed)
                Button(controller.muted ? "Unmute" : "Mute") { controller.setMuted(!controller.muted) }.disabled(controller.state != .listening && controller.state != .muted)
            }
            HStack { TextField("Inject text without microphone", text: $injectedText); Button("Send") { let text = injectedText; injectedText = ""; Task { _ = await controller.inject(text: text) } }.disabled(injectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            if let receipt = controller.lastReceipt { Text("Command \(receipt.status) · \(receipt.correlationID)").font(.caption).foregroundStyle(.secondary) }
        }.padding(22).frame(width: 520)
    }
}
