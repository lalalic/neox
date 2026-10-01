import Foundation

struct NeoYTutorBinding: Codable, Equatable, Sendable {
    let learner: String
    var threadURL: String
    var targetID: String?
    var updatedAt: Date
}

struct NeoYTutorWorkspaceState: Codable, Equatable, Sendable {
    var bindings: [String: NeoYTutorBinding] = [:]
}

enum NeoYTutorError: LocalizedError {
    case invalidLearner
    case invalidThreadURL
    case learnerNotBound(String)
    case platformUnavailable(String)
    case platformFailed(String)
    case invalidPlatformResponse

    var errorDescription: String? {
        switch self {
        case .invalidLearner:
            "learner must be a non-empty stable id"
        case .invalidThreadURL:
            "thread_url must be an https://chatgpt.com thread URL"
        case .learnerNotBound(let learner):
            "learner '\(learner)' is not bound to a ChatGPT thread"
        case .platformUnavailable(let message):
            "ChatGPT browser platform is unavailable: \(message)"
        case .platformFailed(let message):
            "ChatGPT browser turn failed: \(message)"
        case .invalidPlatformResponse:
            "ChatGPT browser platform returned an invalid response"
        }
    }
}

struct NeoYChatGPTTurnResult: Codable, Equatable, Sendable {
    let status: String
    let threadURL: String
    let targetID: String?
    let recovered: Bool
    let text: String
    let assistantMessageID: String?
    let userMessageID: String?
    let verifiedBy: String?
}

struct NeoYChatGPTPlatformRunner: Sendable {
    let root: URL
    let agentWorkspace: URL
    let workspaceName: String
    let workspacePoolSize: Int

    init(
        root: URL? = nil,
        agentWorkspace: URL? = nil,
        workspaceName: String? = nil,
        workspacePoolSize: Int? = nil
    ) {
        if let agentWorkspace {
            self.agentWorkspace = agentWorkspace
        } else if let override = ProcessInfo.processInfo.environment["NEOY_TUTOR_BH_AGENT_WORKSPACE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !override.isEmpty {
            self.agentWorkspace = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        } else {
            self.agentWorkspace = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/browser-harness/agent-workspace", isDirectory: true)
        }

        if let workspaceName {
            self.workspaceName = workspaceName
        } else if let override = ProcessInfo.processInfo.environment["NEOY_TUTOR_BROWSER_WORKSPACE_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !override.isEmpty {
            self.workspaceName = override
        } else {
            self.workspaceName = "Tutor"
        }

        if let workspacePoolSize {
            self.workspacePoolSize = max(1, workspacePoolSize)
        } else if let raw = ProcessInfo.processInfo.environment["NEOY_TUTOR_BROWSER_POOL_SIZE"],
                  let parsed = Int(raw), parsed > 0 {
            self.workspacePoolSize = parsed
        } else {
            self.workspacePoolSize = 8
        }

        if let root {
            self.root = root
            return
        }
        let environment = ProcessInfo.processInfo.environment["NEOY_BROWSER_PLATFORMS_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let environment, !environment.isEmpty {
            self.root = URL(fileURLWithPath: NSString(string: environment).expandingTildeInPath, isDirectory: true)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agents/skills/browser-platforms", isDirectory: true)
        }
    }

    var executable: URL {
        root.appendingPathComponent("platforms/chatgpt/bin/chatgpt-thread-turn")
    }

    var helper: URL {
        agentWorkspace.appendingPathComponent("agent_helpers.py")
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
            && FileManager.default.fileExists(atPath: helper.path)
    }

    func turn(
        threadURL: String,
        targetID: String?,
        prompt: String,
        files: [String],
        timeout: Int = 240
    ) async throws -> NeoYChatGPTTurnResult {
        let executable = self.executable
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NeoYTutorError.platformUnavailable(executable.path)
        }
        guard FileManager.default.fileExists(atPath: helper.path) else {
            throw NeoYTutorError.platformUnavailable("Browser Workspace helper missing at \(helper.path)")
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            var arguments = [
                "--thread-url", threadURL,
                "--prompt", prompt,
                "--result-timeout", String(timeout),
            ]
            if let targetID, !targetID.isEmpty {
                arguments += ["--target-id", targetID]
            }
            for file in files {
                arguments += ["--file", file]
            }
            process.arguments = arguments
            do {
                try FileManager.default.createDirectory(at: agentWorkspace, withIntermediateDirectories: true)
            } catch {
                throw NeoYTutorError.platformUnavailable("could not create Tutor Browser Harness workspace: \(error.localizedDescription)")
            }
            var environment = ProcessInfo.processInfo.environment
            environment["BH_AGENT_WORKSPACE"] = agentWorkspace.path
            environment["BH_WORKSPACE_NAME"] = workspaceName
            environment["BH_WORKSPACE_POOL_SIZE"] = String(workspacePoolSize)
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw NeoYTutorError.platformUnavailable(error.localizedDescription)
            }

            process.waitUntilExit()
            let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let lastLine = output.split(separator: "\n").last,
                  let data = String(lastLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let message = [errorOutput, output].filter { !$0.isEmpty }.joined(separator: "\n")
                if process.terminationStatus != 0 {
                    throw NeoYTutorError.platformFailed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
                }
                throw NeoYTutorError.invalidPlatformResponse
            }

            if process.terminationStatus != 0 || (object["status"] as? String) == "error" {
                throw NeoYTutorError.platformFailed(
                    (object["error"] as? String) ?? errorOutput.ifEmpty("exit \(process.terminationStatus)")
                )
            }

            guard let status = object["status"] as? String,
                  let returnedThreadURL = object["thread_url"] as? String,
                  let text = object["text"] as? String else {
                throw NeoYTutorError.invalidPlatformResponse
            }

            return NeoYChatGPTTurnResult(
                status: status,
                threadURL: returnedThreadURL,
                targetID: object["target_id"] as? String,
                recovered: object["recovered"] as? Bool ?? false,
                text: text,
                assistantMessageID: object["assistant_message_id"] as? String,
                userMessageID: object["user_message_id"] as? String,
                verifiedBy: object["verified_by"] as? String
            )
        }.value
    }
}

actor NeoYTutorWorkspace {
    static let shared = NeoYTutorWorkspace()

    private let stateURL: URL
    private let runner: NeoYChatGPTPlatformRunner
    private var state: NeoYTutorWorkspaceState

    init(
        stateURL: URL = NeoYPaths.supportDirectory.appendingPathComponent("tutor-workspace.json"),
        runner: NeoYChatGPTPlatformRunner = NeoYChatGPTPlatformRunner()
    ) {
        self.stateURL = stateURL
        self.runner = runner
        self.state = Self.load(from: stateURL)
    }

    func snapshot() -> NeoYTutorWorkspaceState { state }

    func statusJSON() -> String {
        let bindings = state.bindings.values.sorted { $0.learner < $1.learner }.map { binding in
            [
                "learner": binding.learner,
                "thread_url": binding.threadURL,
                "target_id": binding.targetID ?? NSNull(),
                "updated_at": ISO8601DateFormatter().string(from: binding.updatedAt),
            ] as [String: Any]
        }
        return Self.jsonString([
            "feature": "tutor",
            "platform": "chatgpt",
            "platform_available": runner.isAvailable,
            "platform_executable": runner.executable.path,
            "browser_agent_workspace": runner.agentWorkspace.path,
            "browser_workspace_name": runner.workspaceName,
            "browser_workspace_pool_size": runner.workspacePoolSize,
            "bindings": bindings,
        ])
    }

    func bind(learner rawLearner: String, threadURL rawThreadURL: String) throws -> String {
        let learner = rawLearner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learner.isEmpty else { throw NeoYTutorError.invalidLearner }
        let threadURL = rawThreadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validThreadURL(threadURL) else { throw NeoYTutorError.invalidThreadURL }

        state.bindings[learner] = NeoYTutorBinding(
            learner: learner,
            threadURL: threadURL,
            targetID: nil,
            updatedAt: Date()
        )
        try persist()
        return Self.jsonString(["status": "bound", "learner": learner, "thread_url": threadURL])
    }

    func unbind(learner rawLearner: String) throws -> String {
        let learner = rawLearner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learner.isEmpty else { throw NeoYTutorError.invalidLearner }
        state.bindings.removeValue(forKey: learner)
        try persist()
        return Self.jsonString(["status": "unbound", "learner": learner])
    }

    func turn(learner rawLearner: String, prompt: String, files: [String]) async throws -> String {
        let learner = rawLearner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learner.isEmpty else { throw NeoYTutorError.invalidLearner }
        guard var binding = state.bindings[learner] else {
            throw NeoYTutorError.learnerNotBound(learner)
        }

        let result = try await runner.turn(
            threadURL: binding.threadURL,
            targetID: binding.targetID,
            prompt: prompt,
            files: files
        )

        binding.threadURL = result.threadURL
        binding.targetID = result.targetID
        binding.updatedAt = Date()
        state.bindings[learner] = binding
        try persist()

        return Self.jsonString([
            "status": result.status,
            "learner": learner,
            "thread_url": result.threadURL,
            "target_id": result.targetID ?? NSNull(),
            "recovered": result.recovered,
            "verified_by": result.verifiedBy ?? NSNull(),
            "user_message_id": result.userMessageID ?? NSNull(),
            "assistant_message_id": result.assistantMessageID ?? NSNull(),
            "text": result.text,
        ])
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private static func load(from url: URL) -> NeoYTutorWorkspaceState {
        guard let data = try? Data(contentsOf: url) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(NeoYTutorWorkspaceState.self, from: data)) ?? .init()
    }

    private static func validThreadURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host?.lowercased() == "chatgpt.com" else { return false }
        return url.path != "/" && !url.path.isEmpty
    }

    private static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{\"status\":\"error\",\"error\":\"json encoding failed\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum NeoYTutorTools {
    static func tools(workspace: NeoYTutorWorkspace = .shared) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "tutor.workspace",
                description: """
                Manage NeoY's fixed Family Tutor workspace. Actions: status, bind, unbind, turn.                 Each learner is bound to one persistent ChatGPT thread. NeoY stores only binding state, never transcripts.
                """,
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "action": .object(["type": .string("string"), "description": .string("status, bind, unbind, or turn")]),
                        "learner": .object(["type": .string("string"), "description": .string("Stable learner id")]),
                        "thread_url": .object(["type": .string("string"), "description": .string("Existing https://chatgpt.com thread URL")]),
                        "prompt": .object(["type": .string("string"), "description": .string("Turn text for action=turn")]),
                        "files": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Optional local attachment paths"),
                        ]),
                    ]),
                    "required": .array([.string("action")]),
                ])
            ) { arguments in
                guard case .object(let object) = arguments,
                      case .string(let action)? = object["action"] else {
                    throw NeoYTutorError.platformFailed("action is required")
                }
                switch action {
                case "status", "list":
                    return await workspace.statusJSON()
                case "bind":
                    guard case .string(let learner)? = object["learner"],
                          case .string(let threadURL)? = object["thread_url"] else {
                        throw NeoYTutorError.platformFailed("bind requires learner and thread_url")
                    }
                    return try await workspace.bind(learner: learner, threadURL: threadURL)
                case "unbind":
                    guard case .string(let learner)? = object["learner"] else {
                        throw NeoYTutorError.platformFailed("unbind requires learner")
                    }
                    return try await workspace.unbind(learner: learner)
                case "turn":
                    guard case .string(let learner)? = object["learner"],
                          case .string(let prompt)? = object["prompt"] else {
                        throw NeoYTutorError.platformFailed("turn requires learner and prompt")
                    }
                    let files: [String]
                    if case .array(let values)? = object["files"] {
                        files = values.compactMap { value in
                            if case .string(let item) = value { return item }
                            return nil
                        }
                    } else {
                        files = []
                    }
                    return try await workspace.turn(learner: learner, prompt: prompt, files: files)
                default:
                    throw NeoYTutorError.platformFailed("unknown tutor action '\(action)'")
                }
            },
        ]
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
