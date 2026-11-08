import Foundation

/// Phone-owned, protected, durable outbox. A message stays here until the
/// authenticated Neo gateway confirms durable ChatGPT queue submission.
struct QueuedChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let text: String
    let createdAt: Date
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
    func enqueue(_ text: String, at: Date = Date()) throws -> QueuedChatMessage {
        let message = QueuedChatMessage(id: UUID().uuidString, text: text, createdAt: at)
        try persist(messages + [message])
        messages.append(message)
        return message
    }

    func acknowledge(_ id: String) throws {
        let remaining = messages.filter { $0.id != id }
        try persist(remaining)
        messages = remaining
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
