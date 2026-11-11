import Darwin
import Foundation

public final class ToolCallAudit: @unchecked Sendable {
    public enum Origin: String, Codable, Sendable {
        case local
        case remote
    }

    public enum Status: String, Codable, Sendable {
        case started
        case succeeded
        /// MCP call succeeded, but the executed shell/terminal command exited nonzero.
        case warning
        case failed
        case denied
        case notFound = "not_found"
    }

    public enum ErrorCode: String, Codable, Sendable {
        case none
        case handlerError = "handler_error"
        case forwardedToolError = "forwarded_tool_error"
        case authorizationDenied = "authorization_denied"
        case invalidRequest = "invalid_request"
        case unknownTool = "unknown_tool"
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public let origin: Origin
        public let provider: String?

        public init(origin: Origin, provider: String?) {
            self.origin = origin
            self.provider = provider
        }
    }

    struct ErrorDetail: Codable, Sendable {
        let code: ErrorCode
        let type: String?
        let domain: String?
        let number: Int?
        let message: String?
        let debug: String?
    }

    /// Preserve the raw error message; access to the audit file is restricted to the user.
    private static func errorDetail(_ error: Error?, code: ErrorCode) -> ErrorDetail {
        guard let error else { return ErrorDetail(code: code, type: nil, domain: nil, number: nil, message: nil, debug: nil) }
        let ns = error as NSError
        let type = String(String(reflecting: Swift.type(of: error)).prefix(120))
        return ErrorDetail(code: code, type: type, domain: ns.domain, number: ns.code, message: error.localizedDescription, debug: String(reflecting: error))
    }

    public struct Entry: Codable, Sendable {
        let time: String
        let callID: String
        let tool: String
        let provenance: Provenance
        let phase: String
        let status: Status
        let durationMS: Int?
        let error: ErrorDetail?
        let input: JSONValue?
        let output: JSONValue?
        let exitCode: Int?
        /// True when an oversized audit record omits raw inputs/outputs.
        let truncated: Bool?

        enum CodingKeys: String, CodingKey {
            case time
            case callID = "call_id"
            case tool
            case provenance
            case phase
            case status
            case durationMS = "duration_ms"
            case error
            case input
            case output
            case exitCode = "exit_code"
            case truncated
        }
    }

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NeoY", isDirectory: true)
        .appendingPathComponent("tool-calls.jsonl", isDirectory: false)

    // Retain at most ~104 MiB of active+rotated audit data by default.
    // Manually archived historical files under `archive/` are not managed here.
    public static let defaultMaxFileBytes = 8 * 1024 * 1024
    public static let defaultMaxArchives = 12
    public static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private let url: URL
    private let maxFileBytes: Int
    private let maxArchives: Int
    private let maxArchiveAge: TimeInterval
    private let writeQueue = DispatchQueue(label: "app.neoy.tool-call-audit", qos: .utility)
    private let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(
        url: URL = ToolCallAudit.defaultURL,
        maxFileBytes: Int = ToolCallAudit.defaultMaxFileBytes,
        maxArchives: Int = ToolCallAudit.defaultMaxArchives,
        maxArchiveAge: TimeInterval = ToolCallAudit.defaultMaxAge
    ) {
        self.url = url
        self.maxFileBytes = max(256, maxFileBytes)
        self.maxArchives = max(0, maxArchives)
        self.maxArchiveAge = max(0, maxArchiveAge)
    }

    public func flush() {
        writeQueue.sync {}
    }

    public func record(
        callID: UUID,
        toolName: String,
        provenance: Provenance,
        status: Status,
        errorCode: ErrorCode = .none,
        underlyingError: Error? = nil,
        input: JSONValue? = nil,
        output: JSONValue? = nil,
        startedAt: Date? = nil
    ) {
        let now = Date()
        let duration = startedAt.map { max(0, Int((now.timeIntervalSince($0) * 1000).rounded())) } ?? 0
        let code = Self.exitCode(from: output)
        // Distinguish an executed command's nonzero exit from an MCP transport
        // failure without changing the tool's actual response or exit code.
        let effectiveStatus: Status = status == .succeeded
            && (toolName == "shell" || toolName == "terminal")
            && code.map({ $0 != 0 }) == true ? .warning : status
        let entry = Entry(
            time: timeFormatter.string(from: now),
            callID: callID.uuidString,
            tool: String(toolName.prefix(256)),
            provenance: provenance,
            phase: status == .started ? "started" : "terminal",
            status: effectiveStatus,
            durationMS: status == .started ? nil : duration,
            error: errorCode == .none ? nil : Self.errorDetail(underlyingError, code: errorCode),
            input: input,
            output: output,
            exitCode: code,
            truncated: nil
        )
        writeQueue.async { [url, maxFileBytes, maxArchives, maxArchiveAge] in
            Self.append(entry, to: url, maxFileBytes: maxFileBytes,
                        maxArchives: maxArchives, maxArchiveAge: maxArchiveAge)
        }
    }

    private static func exitCode(from output: JSONValue?) -> Int? {
        guard case .object(let object) = output else { return nil }
        if case .int(let code) = object["exitCode"] { return code }
        if case .int(let code) = object["exit_code"] { return code }
        // Modern MCP providers may provide structuredContent independently of
        // text content. Inspect it first, without scraping unrelated fields.
        if let structured = object["structuredContent"],
           let code = exitCode(from: structured) { return code }
        // Federated shell providers may wrap their result as MCP text content.
        if case .array(let content) = object["content"] {
            for item in content {
                guard case .object(let part) = item,
                      case .string(let text) = part["text"],
                      let data = text.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
                if let code = exitCode(from: parsed) { return code }
            }
        }
        return nil
    }

    private static func rotatedDirectory(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("audit-rotated", isDirectory: true)
    }

    private static func rotatedPrefix(for url: URL) -> String {
        "\(url.deletingPathExtension().lastPathComponent)-"
    }

    private static func rotatedFiles(for url: URL) -> [URL] {
        let prefix = rotatedPrefix(for: url)
        let directory = rotatedDirectory(for: url)
        return (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl" } ?? []
    }

    /// Runs on the serial audit queue. Prune only machine-managed rotations,
    /// never the owner's separately archived historical files.
    private static func pruneArchives(for url: URL, maxArchives: Int, maxAge: TimeInterval) {
        let files = rotatedFiles(for: url).sorted { $0.lastPathComponent > $1.lastPathComponent }
        let oldestAllowed = Date().addingTimeInterval(-maxAge)
        for (index, file) in files.enumerated() {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if index >= maxArchives || modified.map({ $0 < oldestAllowed }) != false {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func rotateIfNeeded(
        _ url: URL, incomingBytes: Int, maxFileBytes: Int,
        maxArchives: Int, maxArchiveAge: TimeInterval
    ) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let currentBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard currentBytes > 0, currentBytes + incomingBytes > maxFileBytes else { return }
        let directory = rotatedDirectory(for: url)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let suffix = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString)"
        let target = directory.appendingPathComponent("\(rotatedPrefix(for: url))\(suffix).jsonl")
        try FileManager.default.moveItem(at: url, to: target)
        pruneArchives(for: url, maxArchives: maxArchives, maxAge: maxArchiveAge)
    }

    private static func append(
        _ entry: Entry, to url: URL,
        maxFileBytes: Int, maxArchives: Int, maxArchiveAge: TimeInterval
    ) {
        do {
            var data = try JSONEncoder().encode(entry)
            if data.count + 1 > maxFileBytes {
                // JSONL records cannot be split across files. Preserve the
                // call identity/outcome but omit an oversized raw payload.
                let smallError = entry.error.map {
                    ErrorDetail(code: $0.code, type: nil, domain: nil,
                                number: nil, message: nil, debug: nil)
                }
                let redacted = Entry(
                    time: entry.time, callID: entry.callID, tool: entry.tool,
                    provenance: entry.provenance, phase: entry.phase,
                    status: entry.status, durationMS: entry.durationMS,
                    error: smallError, input: nil, output: nil,
                    exitCode: entry.exitCode, truncated: true
                )
                data = try JSONEncoder().encode(redacted)
                guard data.count + 1 <= maxFileBytes else { return }
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
            try rotateIfNeeded(url, incomingBytes: data.count + 1,
                               maxFileBytes: maxFileBytes, maxArchives: maxArchives,
                               maxArchiveAge: maxArchiveAge)
            let descriptor = open(
                url.path,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            fchmod(descriptor, 0o600)

            var line = data
            line.append(0x0A)
            line.withUnsafeBytes { buffer in
                guard var base = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = write(descriptor, base, remaining)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { return }
                    base += written
                    remaining -= written
                }
            }
            // Apply age-based retention even during low-volume periods when
            // the active log has not needed another size-based rollover.
            pruneArchives(for: url, maxArchives: maxArchives, maxAge: maxArchiveAge)
        } catch {
            // Audit logging is best effort; never alter MCP tool execution.
        }
    }
}
