import Foundation
import WebKitAgent

/// Routes incoming WeChat messages to the correct project session.
///
/// Responsibilities:
/// - Look up contactId → projectId via WeChatService bindings
/// - Filter: only text messages, only bound contacts
/// - Log messages to conversation history
/// - Forward to project session (Slice 3 adds this)
@MainActor
final class WeChatMessageRouter {

    private weak var weChatService: WeChatService?
    private weak var coordinator: AgentCoordinator?

    /// Conversation history per project (in-memory, recent messages only).
    private(set) var conversationHistory: [String: [ChatLogEntry]] = [:]

    private static let maxHistoryPerProject = 100

    init(weChatService: WeChatService, coordinator: AgentCoordinator) {
        self.weChatService = weChatService
        self.coordinator = coordinator
    }

    /// Handle an incoming WeChat message. Called from WeChatService.onMessage.
    func route(_ message: WeChatMessage) {
        guard let weChatService else { return }

        // v1: text only
        guard message.isText else { return }

        // Look up which project this contact is bound to
        let contactId = message.routingContactId
        guard let projectId = weChatService.projectForContact(contactId) else {
            // Unbound contact — ignore
            return
        }

        // Get sender info
        let senderName: String
        let senderId: String
        if message.isRoom {
            senderId = message.roomSenderUserName ?? "unknown"
            // Try to resolve sender name from contact list
            senderName = weChatService.contacts
                .first(where: { $0.userName == senderId })?.name ?? senderId
        } else {
            senderId = message.fromUserName
            senderName = message.fromContact?.name ?? senderId
        }

        let cleanText = message.cleanContent
        let weight = weChatService.senderWeight(
            contactId: contactId,
            senderId: message.isRoom ? senderId : nil,
            project: projectId
        )

        // Weight 0 = muted, ignore entirely
        guard weight > 0 else { return }

        // Log to conversation history
        let entry = ChatLogEntry(
            timestamp: Date(),
            sender: senderName,
            senderId: senderId,
            text: cleanText,
            weight: weight,
            projectId: projectId,
            contactId: contactId,
            isRoom: message.isRoom
        )
        appendToHistory(entry, projectId: projectId)

        print("[WeChatRouter] \(senderName) (w:\(weight)) → project '\(projectId)': \(cleanText.prefix(80))")

        // TODO (Slice 3): Forward to project session
        // coordinator?.forwardToProjectSession(projectId: projectId, entry: entry)
    }

    private func appendToHistory(_ entry: ChatLogEntry, projectId: String) {
        var history = conversationHistory[projectId] ?? []
        history.append(entry)
        if history.count > Self.maxHistoryPerProject {
            history.removeFirst(history.count - Self.maxHistoryPerProject)
        }
        conversationHistory[projectId] = history
    }

    /// Get recent history for a project.
    func recentHistory(for projectId: String, limit: Int = 20) -> [ChatLogEntry] {
        let history = conversationHistory[projectId] ?? []
        return Array(history.suffix(limit))
    }
}

// MARK: - Chat Log Entry

struct ChatLogEntry {
    let timestamp: Date
    let sender: String
    let senderId: String
    let text: String
    let weight: Int
    let projectId: String
    let contactId: String
    let isRoom: Bool
}
