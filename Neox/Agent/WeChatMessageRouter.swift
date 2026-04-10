import Foundation
import WebKitAgent
import CopilotChat

/// Routes incoming WeChat messages to the correct project session
/// and sends agent responses back to WeChat.
///
/// Responsibilities:
/// - Look up contactId → projectId via WeChatService bindings
/// - Filter: only text messages, only bound contacts
/// - Log messages to conversation history
/// - Forward to per-project agent session
/// - Route agent responses back to WeChat with correct prefix
@MainActor
final class WeChatMessageRouter {

    private weak var weChatService: WeChatService?
    private weak var coordinator: AgentCoordinator?

    /// Conversation history per project (in-memory, recent messages only).
    private(set) var conversationHistory: [String: [ChatLogEntry]] = [:]

    /// Tracks which contact last triggered a message for each project.
    /// Used to route agent responses back to the correct WeChat conversation.
    private var lastActiveContact: [String: String] = [:]

    private static let maxHistoryPerProject = 100

    init(weChatService: WeChatService, coordinator: AgentCoordinator) {
        self.weChatService = weChatService
        self.coordinator = coordinator
    }

    /// Handle an incoming WeChat message. Called from WeChatService.onMessage.
    func route(_ message: WeChatMessage) {
        guard let weChatService, let coordinator else { return }

        // v1: text only
        guard message.isText else { return }

        // Look up which project this contact is bound to
        let contactId = message.routingContactId
        guard let projectId = weChatService.projectForContact(contactId) else {
            return
        }

        // Get sender info
        let senderName: String
        let senderId: String
        if message.isRoom {
            senderId = message.roomSenderUserName ?? "unknown"
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

        // Track which contact triggered this for response routing
        lastActiveContact[projectId] = contactId

        NSLog("[WeChatRouter] %@ (w:%d) → project '%@': %@", senderName, weight, projectId, String(cleanText.prefix(80)))

        // Get or create per-project session, then forward the message
        let vm = coordinator.createProjectSession(projectId: projectId) { [weak self] response in
            await self?.handleProjectResponse(projectId: projectId, response: response)
        }

        // Format message with sender attribution
        let roomLabel = message.isRoom ? " in \(message.fromContact?.name ?? contactId)" : ""
        let prompt = "[WeChat message from \(senderName) (weight: \(weight))\(roomLabel)]\n\(cleanText)"

        Task {
            let state = vm.chatState
            NSLog("[WeChatRouter] Session state: %@", String(describing: state))
            switch state {
            case .waitingForQuestions, .waitingForUser:
                NSLog("[WeChatRouter] Answering pending question")
                _ = await vm.sendToRelay(prompt)
            case .working:
                NSLog("[WeChatRouter] Agent busy — steering with new message")
                await vm.send(prompt, startAgent: false)
            default:
                NSLog("[WeChatRouter] Starting/sending to agent")
                await vm.send(prompt, startAgent: true)
            }
        }
    }

    /// Handle an agent response from a project session — send back to WeChat.
    private func handleProjectResponse(projectId: String, response: String) async {
        guard let weChatService, let coordinator else { return }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Determine prefix based on project type
        let projectType = coordinator.readProjectType(projectId: projectId)
        let formatted: String
        if projectType == "wechat-assistant" {
            formatted = trimmed
        } else {
            formatted = "🤖 \(trimmed)"
        }

        guard let contactId = lastActiveContact[projectId] else {
            NSLog("[WeChatRouter] No active contact for project '%@' — dropping response", projectId)
            return
        }

        NSLog("[WeChatRouter] Response → %@: %@", contactId, String(formatted.prefix(80)))
        await weChatService.sendToContact(contactId, message: formatted, watermark: true)
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
