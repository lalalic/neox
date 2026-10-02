import Foundation
import Darwin

private struct NeoYFileReadResult: Codable, Sendable {
    let path: String
    let encoding: String
    let offset: UInt64
    let bytes: Int
    let size: UInt64
    let truncated: Bool
    let content: String
}

private struct NeoYFileStatResult: Codable, Sendable {
    let path: String
    let kind: String
    let size: UInt64
    let permissions: String
    let modifiedAt: Date?
    let symlinkTarget: String?
}

actor NeoYCoreFileService {
    func execute(_ raw: String) async throws -> String {
        let parsed = try NeoYCommandLine.parse(raw)
        guard let verb = parsed.tokens.first else { return Self.help }
        switch verb {
        case "help": return Self.help
        case "read": return try read(parsed.tokens)
        case "write": return try write(parsed, append: false)
        case "append": return try write(parsed, append: true)
        case "stat": return try stat(parsed.tokens)
        case "list": return try list(parsed.tokens)
        case "mkdir": return try mkdir(parsed.tokens)
        case "remove": return try remove(parsed.tokens)
        case "move": return try move(parsed.tokens)
        case "copy": return try copy(parsed.tokens)
        case "chmod": return try chmodCommand(parsed.tokens)
        case "symlink": return try symlink(parsed.tokens)
        default: throw NeoYCoreError.invalidCommand("unknown mac.fs command '\(verb)'; run 'help'")
        }
    }

    private func read(_ tokens: [String]) throws -> String {
        guard tokens.count >= 2 else { throw NeoYCoreError.missingArgument("read <path> [--offset N] [--max-bytes N] [--base64]") }
        let url = url(tokens[1])
        var offset: UInt64 = 0
        var maxBytes = 1_000_000
        var base64 = false
        var i = 2
        while i < tokens.count {
            switch tokens[i] {
            case "--offset":
                guard i + 1 < tokens.count, let value = UInt64(tokens[i + 1]) else { throw NeoYCoreError.invalidCommand("invalid --offset") }
                offset = value; i += 2
            case "--max-bytes":
                guard i + 1 < tokens.count, let value = Int(tokens[i + 1]) else { throw NeoYCoreError.invalidCommand("invalid --max-bytes") }
                maxBytes = min(max(value, 1), 64_000_000); i += 2
            case "--base64":
                base64 = true; i += 1
            default:
                throw NeoYCoreError.invalidCommand("unexpected option '\(tokens[i])'")
            }
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = min(offset, size)
        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        let result = NeoYFileReadResult(
            path: url.path,
            encoding: base64 ? "base64" : "utf8",
            offset: start,
            bytes: data.count,
            size: size,
            truncated: start + UInt64(data.count) < size,
            content: base64 ? data.base64EncodedString() : String(decoding: data, as: UTF8.self)
        )
        return NeoYCoreJSON.encode(result)
    }

    private func write(_ parsed: NeoYCommandLine.Parsed, append: Bool) throws -> String {
        guard parsed.tokens.count >= 2 else { throw NeoYCoreError.missingArgument("\(append ? "append" : "write") <path> [--base64] -- <content>") }
        let target = url(parsed.tokens[1])
        let base64 = parsed.tokens.dropFirst(2).contains("--base64")
        guard let remainder = parsed.remainder else { throw NeoYCoreError.missingArgument("content after --") }
        let data: Data
        if base64 {
            guard let decoded = Data(base64Encoded: remainder) else { throw NeoYCoreError.invalidCommand("invalid base64 content") }
            data = decoded
        } else {
            data = Data(remainder.utf8)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        if append {
            if !FileManager.default.fileExists(atPath: target.path) {
                FileManager.default.createFile(atPath: target.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        }
        return NeoYCoreJSON.encode(["path": target.path, "bytes": String(data.count), "append": String(append)])
    }

    private func stat(_ tokens: [String]) throws -> String {
        guard tokens.count == 2 else { throw NeoYCoreError.invalidCommand("usage: stat <path>") }
        let target = url(tokens[1])
        var info = Darwin.stat()
        guard lstat(target.path, &info) == 0 else {
            throw NeoYCoreError.notFound("stat failed for '\(target.path)': \(String(cString: strerror(errno)))")
        }
        let mode = info.st_mode
        let kind: String
        if (mode & S_IFMT) == S_IFDIR { kind = "directory" }
        else if (mode & S_IFMT) == S_IFLNK { kind = "symlink" }
        else if (mode & S_IFMT) == S_IFREG { kind = "file" }
        else { kind = "other" }
        let targetValue: String?
        if kind == "symlink" { targetValue = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) }
        else { targetValue = nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return NeoYCoreJSON.encode(NeoYFileStatResult(
            path: target.path,
            kind: kind,
            size: UInt64(info.st_size),
            permissions: String(format: "%04o", mode & 0o7777),
            modifiedAt: modified,
            symlinkTarget: targetValue
        ))
    }

    private func list(_ tokens: [String]) throws -> String {
        guard tokens.count >= 2 else { throw NeoYCoreError.missingArgument("list <path> [--limit N]") }
        let target = url(tokens[1])
        var limit = 500
        if let i = tokens.firstIndex(of: "--limit"), tokens.indices.contains(i + 1), let value = Int(tokens[i + 1]) {
            limit = min(max(value, 1), 5_000)
        }
        struct Entry: Codable {
            let name: String
            let kind: String
            let size: UInt64?
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        let entries = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: keys)
            .prefix(limit)
            .map { item -> Entry in
                let values = try? item.resourceValues(forKeys: Set(keys))
                let kind = values?.isDirectory == true ? "directory" :
                    (values?.isSymbolicLink == true ? "symlink" : (values?.isRegularFile == true ? "file" : "other"))
                return Entry(name: item.lastPathComponent, kind: kind, size: values?.fileSize.map(UInt64.init))
            }
        return NeoYCoreJSON.encode(Array(entries))
    }

    private func mkdir(_ tokens: [String]) throws -> String {
        guard tokens.count == 2 else { throw NeoYCoreError.invalidCommand("usage: mkdir <path>") }
        let target = url(tokens[1])
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return "{\"ok\":true,\"path\":\"\(escape(target.path))\"}"
    }

    private func remove(_ tokens: [String]) throws -> String {
        guard tokens.count == 2 else { throw NeoYCoreError.invalidCommand("usage: remove <path>") }
        let target = url(tokens[1])
        try FileManager.default.removeItem(at: target)
        return "{\"ok\":true,\"path\":\"\(escape(target.path))\"}"
    }

    private func move(_ tokens: [String]) throws -> String {
        guard tokens.count == 3 else { throw NeoYCoreError.invalidCommand("usage: move <source> <destination>") }
        let source = url(tokens[1]), destination = url(tokens[2])
        try FileManager.default.moveItem(at: source, to: destination)
        return "{\"ok\":true,\"source\":\"\(escape(source.path))\",\"destination\":\"\(escape(destination.path))\"}"
    }

    private func copy(_ tokens: [String]) throws -> String {
        guard tokens.count == 3 else { throw NeoYCoreError.invalidCommand("usage: copy <source> <destination>") }
        let source = url(tokens[1]), destination = url(tokens[2])
        try FileManager.default.copyItem(at: source, to: destination)
        return "{\"ok\":true,\"source\":\"\(escape(source.path))\",\"destination\":\"\(escape(destination.path))\"}"
    }

    private func chmodCommand(_ tokens: [String]) throws -> String {
        guard tokens.count == 3, let mode = Int(tokens[1], radix: 8) else {
            throw NeoYCoreError.invalidCommand("usage: chmod <octal-mode> <path>")
        }
        let target = url(tokens[2])
        guard Darwin.chmod(target.path, mode_t(mode)) == 0 else {
            throw NeoYCoreError.operationFailed("chmod failed: \(String(cString: strerror(errno)))")
        }
        return "{\"ok\":true,\"path\":\"\(escape(target.path))\",\"mode\":\"\(tokens[1])\"}"
    }

    private func symlink(_ tokens: [String]) throws -> String {
        guard tokens.count == 3 else { throw NeoYCoreError.invalidCommand("usage: symlink <target> <link-path>") }
        let link = url(tokens[2])
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: expand(tokens[1]))
        return "{\"ok\":true,\"path\":\"\(escape(link.path))\"}"
    }

    private func url(_ raw: String) -> URL {
        URL(fileURLWithPath: expand(raw))
    }

    private func expand(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static let help = """
    mac.fs — filesystem operations with NeoY's macOS user permissions
      read <path> [--offset N] [--max-bytes N] [--base64]
      write <path> [--base64] -- <content>
      append <path> [--base64] -- <content>
      stat <path>
      list <path> [--limit N]
      mkdir <path>
      remove <path>
      move <source> <destination>
      copy <source> <destination>
      chmod <octal-mode> <path>
      symlink <target> <link-path>
    Quote paths containing spaces. write replaces atomically; append creates the file when missing.
    """
}

enum NeoYFileTools {
    static func tools(service: NeoYCoreFileService) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "mac.fs",
                description: "Core filesystem read/write/stat/list/manage operations. Call with command='help' for authoritative grammar.",
                parameters: NeoYCoreJSON.string("CLI-like filesystem command; use 'help' for grammar")
            ) { arguments in
                try await service.execute(NeoYCoreJSON.command(from: arguments))
            }
        ]
    }
}
