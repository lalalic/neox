import Foundation

struct NeoYSSHAddress: Equatable, Sendable {
    let user: String
    let host: String
    let port: Int

    var target: String { "\(user)@\(host)" }

    var isLoopback: Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static func parse(_ raw: String) throws -> NeoYSSHAddress {
        let parts = raw.components(separatedBy: "#port=")
        guard parts.count <= 2 else {
            throw NeoYCoreError.invalidCommand("invalid SSH target '\(raw)'; expected <user>@<host>[#port=<port>]")
        }
        let target = parts[0]
        guard let at = target.lastIndex(of: "@"),
              at != target.startIndex,
              target.index(after: at) != target.endIndex else {
            throw NeoYCoreError.invalidCommand("invalid SSH target '\(raw)'; expected <user>@<host>[#port=<port>]")
        }
        let user = String(target[..<at])
        let host = String(target[target.index(after: at)...])
        let port: Int
        if parts.count == 2 {
            guard let value = Int(parts[1]), (1...65535).contains(value) else {
                throw NeoYCoreError.invalidCommand("invalid SSH port in '\(raw)'")
            }
            port = value
        } else {
            port = 22
        }
        return NeoYSSHAddress(user: user, host: host, port: port)
    }
}

struct NeoYSSHCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum NeoYSSHBootstrap {
    struct ReverseSSH: Equatable, Sendable {
        let target: String
        let port: Int
        let identityFile: String?
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> NeoYSSHCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return NeoYSSHCommandResult(stdout: out, stderr: err, exitCode: process.terminationStatus)
    }

    static func ssh(_ address: NeoYSSHAddress, command: String) throws -> NeoYSSHCommandResult {
        try run("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", String(address.port),
            address.target,
            command
        ])
    }

    static func scp(_ local: URL, to address: NeoYSSHAddress, remotePath: String) throws -> NeoYSSHCommandResult {
        try run("/usr/bin/scp", [
            "-q",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-P", String(address.port),
            local.path,
            "\(address.target):\(remotePath)"
        ])
    }

    static func parseReverseSSH(from processList: String) -> ReverseSSH? {
        for line in processList.split(separator: "\n").map(String.init) {
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.contains("-R") || words.contains(where: { $0.hasPrefix("-R") }) else { continue }

            var port = 22
            var identity: String?
            var i = 0
            while i < words.count {
                if words[i] == "-p", i + 1 < words.count, let value = Int(words[i + 1]) {
                    port = value
                    i += 2
                    continue
                }
                if words[i] == "-i", i + 1 < words.count {
                    identity = words[i + 1]
                    i += 2
                    continue
                }
                i += 1
            }
            if let target = words.reversed().first(where: {
                $0.contains("@") && !$0.hasPrefix("-") && !$0.contains(":127.0.0.1:")
            }) {
                return ReverseSSH(target: target, port: port, identityFile: identity)
            }
        }
        return nil
    }
}
