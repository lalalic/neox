import Foundation
import CryptoKit

/// Phone-owned, protected, durable outbox. A message stays here until the
/// authenticated Neo gateway confirms durable ChatGPT queue submission.
struct ChatLocalAttachment: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let size: Int
    let sha256: String
}

struct QueuedChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    let createdAt: Date
    /// Optional for backward compatibility with messages queued before attachments existed.
    let attachments: [ChatLocalAttachment]?
}

@MainActor
final class ChatGatewayOutbox {
    private let file: URL
    private(set) var messages: [QueuedChatMessage]

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("neo-chat-outbox.json")
        if let data = try? Data(contentsOf: self.file),
           let saved = try? JSONDecoder().decode([QueuedChatMessage].self, from: data) {
            messages = saved
        } else {
            messages = []
        }
    }

    @discardableResult
    func enqueue(_ text: String, attachments: [ChatLocalAttachment] = [], at: Date = Date()) throws -> QueuedChatMessage {
        let message = QueuedChatMessage(id: UUID().uuidString, text: text, createdAt: at,
                                        attachments: attachments)
        try persist(messages + [message])
        messages.append(message)
        return message
    }

    func acknowledge(_ id: String) throws {
        let sent = messages.first { $0.id == id }
        let remaining = messages.filter { $0.id != id }
        try persist(remaining)
        messages = remaining
        for attachment in sent?.attachments ?? [] {
            try? FileManager.default.removeItem(atPath: attachment.path)
        }
    }

    func stage(_ data: Data, name rawName: String) throws -> ChatLocalAttachment {
        guard !data.isEmpty && data.count <= 12 * 1024 * 1024 else {
            throw NSError(domain: "ChatAttachment", code: 1)
        }
        let raw = URL(fileURLWithPath: rawName).lastPathComponent
        let name = String(raw.unicodeScalars.filter {
            $0.value >= 32 && $0 != "/" && $0 != "\\"
        }.prefix(120))
        guard !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") else {
            throw NSError(domain: "ChatAttachment", code: 2)
        }
        let id = UUID().uuidString
        let directory = file.deletingLastPathComponent()
            .appendingPathComponent("neo-chat-files").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ChatLocalAttachment(id: id, name: name, path: destination.path,
                                   size: data.count, sha256: checksum)
    }

    func stage(fileURL: URL) throws -> ChatLocalAttachment {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 && size <= 12 * 1024 * 1024 else {
            throw NSError(domain: "ChatAttachment", code: 3)
        }
        return try stage(Data(contentsOf: fileURL), name: fileURL.lastPathComponent)
    }

    func discard(_ attachment: ChatLocalAttachment) {
        // Never discard an attachment already retained by a queued message.
        guard !messages.contains(where: { $0.attachments?.contains(attachment) == true }) else { return }
        try? FileManager.default.removeItem(atPath: attachment.path)
    }

    private func persist(_ values: [QueuedChatMessage]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: file.path)
    }
}
