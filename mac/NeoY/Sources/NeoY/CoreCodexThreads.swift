import Foundation

actor NeoYCodexThreadService {
    func execute(_ raw: String) async throws -> String {
        let parsed = try NeoYCommandLine.parse(raw)
        guard let verb = parsed.tokens.first else { return Self.help }
        switch verb {
        case "help": return Self.help
        case "list": return try list(parsed.tokens)
        case "read": return try read(parsed.tokens)
        case "turns": return try turns(parsed.tokens)
        default: throw NeoYCoreError.invalidCommand("unknown codex.threads command '\(verb)'; run 'help'")
        }
    }

    private func list(_ tokens: [String]) throws -> String {
        var params: [String: Any] = ["limit": 50, "sortKey": "recency_at", "sortDirection": "desc"]
        var i = 1
        while i < tokens.count {
            switch tokens[i] {
            case "--limit":
                guard i + 1 < tokens.count, let value = Int(tokens[i + 1]), (1...200).contains(value) else {
                    throw NeoYCoreError.invalidCommand("invalid --limit")
                }
                params["limit"] = value; i += 2
            case "--search":
                guard i + 1 < tokens.count else { throw NeoYCoreError.missingArgument("--search TERM") }
                params["searchTerm"] = tokens[i + 1]; i += 2
            case "--cwd":
                guard i + 1 < tokens.count else { throw NeoYCoreError.missingArgument("--cwd PATH") }
                params["cwd"] = expand(tokens[i + 1]); i += 2
            case "--cursor":
                guard i + 1 < tokens.count else { throw NeoYCoreError.missingArgument("--cursor VALUE") }
                params["cursor"] = tokens[i + 1]; i += 2
            case "--archived":
                params["archived"] = true; i += 1
            default:
                throw NeoYCoreError.invalidCommand("unexpected option '\(tokens[i])'")
            }
        }
        return try call(method: "thread/list", params: params)
    }

    private func read(_ tokens: [String]) throws -> String {
        guard tokens.count >= 2 else { throw NeoYCoreError.missingArgument("read <thread-id> [--no-turns]") }
        let includeTurns = !tokens.contains("--no-turns")
        return try call(method: "thread/read", params: [
            "threadId": tokens[1],
            "includeTurns": includeTurns
        ])
    }

    private func turns(_ tokens: [String]) throws -> String {
        guard tokens.count >= 2 else {
            throw NeoYCoreError.missingArgument("turns <thread-id> [--limit N] [--cursor VALUE] [--summary]")
        }
        var params: [String: Any] = [
            "threadId": tokens[1],
            "limit": 50,
            "sortDirection": "asc",
            "itemsView": tokens.contains("--summary") ? "summary" : "full"
        ]
        var i = 2
        while i < tokens.count {
            switch tokens[i] {
            case "--limit":
                guard i + 1 < tokens.count, let value = Int(tokens[i + 1]), (1...200).contains(value) else {
                    throw NeoYCoreError.invalidCommand("invalid --limit")
                }
                params["limit"] = value; i += 2
            case "--cursor":
                guard i + 1 < tokens.count else { throw NeoYCoreError.missingArgument("--cursor VALUE") }
                params["cursor"] = tokens[i + 1]; i += 2
            case "--summary":
                i += 1
            default:
                throw NeoYCoreError.invalidCommand("unexpected option '\(tokens[i])'")
            }
        }
        return try call(method: "thread/turns/list", params: params)
    }

    private func call(method: String, params: [String: Any]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        func write(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            var line = data
            line.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: line)
        }

        try write([
            "id": 0,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "NeoY", "title": "NeoY", "version": "2.2.1"],
                "capabilities": ["experimentalApi": true]
            ]
        ])

        var buffer = Data()
        var requestSent = false
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                usleep(10_000)
                continue
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if id == 0 && !requestSent {
                    try write(["method": "initialized", "params": [:]])
                    try write(["id": 1, "method": method, "params": params])
                    requestSent = true
                } else if id == 1 {
                    if let error = message["error"] as? [String: Any] {
                        throw NeoYCoreError.operationFailed(
                            "Codex app-server error: \(error["message"] as? String ?? String(describing: error))"
                        )
                    }
                    let result = message["result"] ?? NSNull()
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
                    return String(decoding: data, as: UTF8.self)
                }
            }
        }

        let stderr = errors.fileHandleForReading.availableData
        throw NeoYCoreError.operationFailed(
            "Codex app-server did not respond: \(String(decoding: stderr, as: UTF8.self))"
        )
    }

    private func expand(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    static let help = """
    codex.threads — read persisted local Codex history without starting model turns
      list [--limit 1..200] [--search TERM] [--cwd PATH] [--cursor VALUE] [--archived]
      read <thread-id> [--no-turns]
      turns <thread-id> [--limit 1..200] [--cursor VALUE] [--summary]
    This v2.2 Core tool is intentionally read-only.
    """
}

enum NeoYCodexThreadTools {
    static func tools(service: NeoYCodexThreadService) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "codex.threads",
                description: "Read-only local Codex thread list/read/turn history. Call with command='help' for authoritative grammar.",
                parameters: NeoYCoreJSON.string("CLI-like Codex thread command; use 'help' for grammar")
            ) { arguments in
                try await service.execute(NeoYCoreJSON.command(from: arguments))
            }
        ]
    }
}
