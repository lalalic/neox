import Foundation

struct NeoYFeatureBootstrapState: Codable, Equatable, Sendable {
    var feature: String
    var sessionID: String
    var phase: String
    var threadURL: String?
    var targetID: String?
    var actionURL: String?
    var message: String
    var updatedAt: Date
}

actor NeoYFeatureBootstrapService {
    static let shared = NeoYFeatureBootstrapService()

    private let stateURL: URL
    private let events: NeoYEventsBusClient
    private var states: [String: NeoYFeatureBootstrapState]

    init(
        stateURL: URL = NeoYPaths.supportDirectory.appendingPathComponent("feature-bootstrap.json"),
        events: NeoYEventsBusClient = NeoYEventsBusClient()
    ) {
        self.stateURL = stateURL
        self.events = events
        self.states = Self.load(stateURL)
    }

    func status(feature: String?) -> String {
        let values = states.values
            .filter { feature == nil || $0.feature == feature }
            .sorted { $0.feature < $1.feature }
        return Self.json(["features": values.map(Self.object)])
    }

    func start(feature rawFeature: String) async throws -> String {
        let feature = rawFeature.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard feature == "tutor" else {
            throw NeoYTutorError.platformFailed("unsupported bootstrap feature '\(feature)'")
        }

        let sessionID = "bootstrap-" + UUID().uuidString.lowercased()
        let actionURL = ProcessInfo.processInfo.environment["NEOY_TUTOR_DISCORD_INSTALL_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let prompt = """
        You are the temporary setup assistant for NeoY's Family Tutor feature.
        This conversation exists only to guide setup; it is not the learner's tutor thread.
        The setup order is:
        1. Connect the family's Discord server using the official Family Tutor bot.
        2. Wait for NeoY to receive the Discord-connected event.
        3. NeoY automatically discovers parents and child channels.
        4. NeoY automatically creates or reuses one ChatGPT Project/thread per child.
        Do not ask the user to create a Discord bot, paste bot tokens, create ChatGPT Projects, or paste thread URLs.
        Tell the user to use the Connect Discord action shown by NeoY, then wait for completion.
        """

        var state = NeoYFeatureBootstrapState(
            feature: feature,
            sessionID: sessionID,
            phase: actionURL?.isEmpty == false ? "waiting_user_action" : "blocked",
            threadURL: nil,
            targetID: nil,
            actionURL: actionURL,
            message: actionURL?.isEmpty == false
                ? "Connect Discord to continue."
                : "Official Discord install URL is not configured.",
            updatedAt: Date()
        )

        if let result = try await startTemporaryThread(instructions: prompt) {
            state.threadURL = result.threadURL
            state.targetID = result.targetID
        }
        states[feature] = state
        try persist()
        try? await publish(state, type: "feature.bootstrap.started", status: state.phase == "blocked" ? "blocked" : "waiting")
        return Self.json(Self.object(state))
    }

    func receive(feature rawFeature: String, type: String, data: [String: JSONValue]) async throws -> String {
        let feature = rawFeature.lowercased()
        guard var state = states[feature] else {
            throw NeoYTutorError.platformFailed("bootstrap for '\(feature)' has not started")
        }
        switch (feature, type) {
        case ("tutor", "discord.connected"):
            state.phase = "discovering"
            state.message = "Discord connected. Discovering family structure."
        case ("tutor", "family.discovered"):
            state.phase = "finalizing"
            state.message = "Family discovered. Creating learner Tutor workspaces."
        case ("tutor", "bootstrap.completed"):
            state.phase = "ready"
            state.message = "Family Tutor is ready."
        default:
            state.phase = "waiting"
            state.message = "Event received: \(type)"
        }
        state.updatedAt = Date()
        states[feature] = state
        try persist()
        try? await publish(state, type: "feature.\(feature).\(type)", status: state.phase == "ready" ? "succeeded" : "running", data: data)
        return Self.json(Self.object(state))
    }

    func reset(feature rawFeature: String) throws -> String {
        let feature = rawFeature.lowercased()
        states.removeValue(forKey: feature)
        try persist()
        return Self.json(["status": "reset", "feature": feature])
    }

    private func startTemporaryThread(instructions: String) async throws -> (threadURL: String, targetID: String?)? {
        let root: URL
        if let override = ProcessInfo.processInfo.environment["NEOY_BROWSER_PLATFORMS_ROOT"], !override.isEmpty {
            root = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills/browser-platforms", isDirectory: true)
        }
        let executable = root.appendingPathComponent("platforms/chatgpt/bin/chatgpt-bootstrap-start")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }

        return try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--instructions", instructions]
            var env = ProcessInfo.processInfo.environment
            env["BH_AGENT_WORKSPACE"] = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/browser-harness/agent-workspace").path
            env["BH_WORKSPACE_NAME"] = "Bootstrap"
            env["BH_WORKSPACE_POOL_SIZE"] = "3"
            process.environment = env
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard let line = text.split(separator: "\n").last,
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let threadURL = object["thread_url"] as? String else { return nil }
            return (threadURL, object["target_id"] as? String)
        }.value
    }

    private func publish(
        _ state: NeoYFeatureBootstrapState,
        type: String,
        status: String,
        data: [String: JSONValue] = [:]
    ) async throws {
        let event: [String: Any] = [
            "job_id": state.sessionID,
            "task_id": state.feature,
            "type": type,
            "status": status,
            "visibility": "orchestrator",
            "message": state.message,
            "source": ["id": "neoy/feature-bootstrap/\(state.feature)"],
            "data": data.mapValues { $0.bootstrapFoundationValue },
        ]
        _ = try await events.publish(event: event)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(states).write(to: stateURL, options: .atomic)
    }

    private static func load(_ url: URL) -> [String: NeoYFeatureBootstrapState] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: NeoYFeatureBootstrapState].self, from: data)) ?? [:]
    }

    private static func object(_ state: NeoYFeatureBootstrapState) -> [String: Any] {
        [
            "feature": state.feature,
            "session_id": state.sessionID,
            "phase": state.phase,
            "thread_url": state.threadURL ?? NSNull(),
            "target_id": state.targetID ?? NSNull(),
            "action_url": state.actionURL ?? NSNull(),
            "message": state.message,
            "updated_at": ISO8601DateFormatter().string(from: state.updatedAt),
        ]
    }

    private static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

enum NeoYFeatureBootstrapTools {
    static func tools(service: NeoYFeatureBootstrapService = .shared) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "feature.bootstrap",
                description: "Initialize and advance a NeoY feature through its temporary ChatGPT bootstrap flow. Actions: start, status, event, reset.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string")]),
                        "feature": .object(["type": .string("string")]),
                        "event_type": .object(["type": .string("string")]),
                        "data": .object(["type": .string("object")]),
                    ]),
                    "required": .array([.string("action")]),
                ])
            ) { arguments in
                guard case .object(let object) = arguments,
                      case .string(let action)? = object["action"] else {
                    throw NeoYTutorError.platformFailed("feature.bootstrap action is required")
                }
                let feature: String?
                if case .string(let value)? = object["feature"] { feature = value } else { feature = nil }
                switch action {
                case "status":
                    return await service.status(feature: feature)
                case "start":
                    guard let feature else { throw NeoYTutorError.platformFailed("start requires feature") }
                    return try await service.start(feature: feature)
                case "event":
                    guard let feature, case .string(let type)? = object["event_type"] else {
                        throw NeoYTutorError.platformFailed("event requires feature and event_type")
                    }
                    let data: [String: JSONValue]
                    if case .object(let value)? = object["data"] { data = value } else { data = [:] }
                    return try await service.receive(feature: feature, type: type, data: data)
                case "reset":
                    guard let feature else { throw NeoYTutorError.platformFailed("reset requires feature") }
                    return try await service.reset(feature: feature)
                default:
                    throw NeoYTutorError.platformFailed("unknown feature.bootstrap action '\(action)'")
                }
            },
        ]
    }
}

private extension JSONValue {
    var bootstrapFoundationValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .null: NSNull()
        case .array(let values): values.map { $0.bootstrapFoundationValue }
        case .object(let values): values.mapValues { $0.bootstrapFoundationValue }
        }
    }
}
