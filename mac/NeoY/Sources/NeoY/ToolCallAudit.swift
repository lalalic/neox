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

        enum CodingKeys: String, CodingKey {
            case time
            case callID = "call_id"
            case tool
            case provenance
            case phase
            case status
            case durationMS = "duration_ms"
            case error
        }
    }

    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NeoY", isDirectory: true)
        .appendingPathComponent("tool-calls.jsonl", isDirectory: false)

    private let url: URL
    private let writeQueue = DispatchQueue(label: "app.neoy.tool-call-audit", qos: .utility)
    private let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(url: URL = ToolCallAudit.defaultURL) {
        self.url = url
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
        startedAt: Date? = nil
    ) {
        let now = Date()
        let duration = startedAt.map { max(0, Int((now.timeIntervalSince($0) * 1000).rounded())) } ?? 0
        let entry = Entry(
            time: timeFormatter.string(from: now),
            callID: callID.uuidString,
            tool: String(toolName.prefix(256)),
            provenance: provenance,
            phase: status == .started ? "started" : "terminal",
            status: status,
            durationMS: status == .started ? nil : duration,
            error: errorCode == .none ? nil : ErrorDetail(code: errorCode)
        )
        writeQueue.async { [url] in
            Self.append(entry, to: url)
        }
    }

    private static func append(_ entry: Entry, to url: URL) {
        do {
            let data = try JSONEncoder().encode(entry)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let descriptor = open(
                url.path,
                O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
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
                    guard written > 0 else { return }
                    base += written
                    remaining -= written
                }
            }
        } catch {
            // Audit logging is deliberately best effort and must not alter MCP execution.
        }
    }
}
