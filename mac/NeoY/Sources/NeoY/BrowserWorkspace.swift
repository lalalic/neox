import Foundation

struct NeoYBrowserWorkspace: Sendable {
    private let exec: NeoYExecService

    init(exec: NeoYExecService = NeoYExecService()) {
        self.exec = exec
    }

    func run(
        action: String,
        config: [String: Any],
        workspace: String,
        poolSize: Int
    ) async throws -> [String: Any] {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-browser-workspace-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: config).write(to: configURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: configURL) }

        _ = try await invoke(
            "browser-workspace create \(Self.shellQuote(workspace)) \(max(1, poolSize))"
        )
        let start = try await invoke(
            "browser-workspace session start --workspace \(Self.shellQuote(workspace))"
        )
        guard let sessionID = Self.lastJSONObject(start)?["session_id"] as? String else {
            throw NeoYTutorError.platformFailed("Browser Workspace session start returned no session_id")
        }

        do {
            let code = Self.actionCode(action: action, configPath: configURL.path)
            let execution = try await invoke(
                "browser-workspace session exec \(Self.shellQuote(sessionID))",
                stdin: code,
                timeout: 600
            )
            guard let wrapper = Self.lastJSONObject(execution),
                  wrapper["ok"] as? Bool == true else {
                let error = Self.lastJSONObject(execution)?["error"] as? String
                throw NeoYTutorError.platformFailed(error ?? execution)
            }
            guard let stdout = wrapper["stdout"] as? String,
                  let result = Self.lastJSONObject(stdout) else {
                throw NeoYTutorError.invalidPlatformResponse
            }
            _ = try? await invoke(
                "browser-workspace session stop \(Self.shellQuote(sessionID))"
            )
            return result
        } catch {
            _ = try? await invoke(
                "browser-workspace session stop \(Self.shellQuote(sessionID))"
            )
            throw error
        }
    }

    func available() async -> Bool {
        (try? await invoke("browser-workspace session --help", timeout: 10)) != nil
    }

    private func invoke(
        _ command: String,
        stdin: String? = nil,
        timeout: Int = 60
    ) async throws -> String {
        let input = stdin.map { " --stdin-base64 \(Data($0.utf8).base64EncodedString())" } ?? ""
        let raw = try await exec.execute(
            "run --timeout \(timeout) --max-output 1000000\(input) -- \(command)"
        )
        guard let object = Self.lastJSONObject(raw),
              let exitCode = object["exitCode"] as? NSNumber,
              exitCode.intValue == 0 else {
            let object = Self.lastJSONObject(raw)
            let stderr = object?["stderr"] as? String
            let stdout = object?["stdout"] as? String
            let stderrText = (stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutText = (stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw NeoYTutorError.platformFailed(
                !stderrText.isEmpty ? stderrText : (!stdoutText.isEmpty ? stdoutText : "Browser Workspace command failed")
            )
        }
        return (object["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func actionCode(action: String, configPath: String) -> String {
        """
        from pathlib import Path
        from platform_runner import action_path, prepare_action
        _source = prepare_action(action_path("chatgpt", \(pythonString(action))), Path(\(pythonString(configPath))))
        exec(compile(_source, "<neoy-browser-workspace-action>", "exec"), globals(), globals())
        """
    }

    private static func lastJSONObject(_ text: String) -> [String: Any]? {
        for line in text.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }

    private static func pythonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
