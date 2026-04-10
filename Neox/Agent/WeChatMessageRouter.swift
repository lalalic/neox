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
    private var routingAgent: WeChatRoutingAgent?
    private var answerConstructor: WeChatAnswerConstructor?
    private(set) var guardrails: WeChatGuardrails?

    /// Conversation history per project (in-memory, recent messages only).
    private(set) var conversationHistory: [String: [ChatLogEntry]] = [:]

    /// Tracks which contact last triggered a message for each project.
    /// Used to route agent responses back to the correct WeChat conversation.
    private(set) var lastActiveContact: [String: String] = [:]

    /// Tracks the last incoming message text per project (for response-level guardrails).
    private(set) var lastIncomingText: [String: String] = [:]

    /// Debug log of recent response events (newest first, max 10).
    private(set) var responseLog: [String] = []

    private static let maxHistoryPerProject = 100

    init(weChatService: WeChatService, coordinator: AgentCoordinator) {
        self.weChatService = weChatService
        self.coordinator = coordinator
        self.routingAgent = WeChatRoutingAgent(coordinator: coordinator)
        self.answerConstructor = WeChatAnswerConstructor(coordinator: coordinator) { [weak self] projectId, answer in
            await self?.handleTimeoutAnswer(projectId: projectId, answer: answer)
        }
        self.guardrails = WeChatGuardrails(weChatService: weChatService)
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
        lastIncomingText[projectId] = cleanText
        // Update thread-safe ref for guardrails tool handler
        coordinator.contactIdRefs[projectId]?.value = contactId

        NSLog("[WeChatRouter] %@ (w:%d) → project '%@': %@", senderName, weight, projectId, String(cleanText.prefix(80)))

        // Get or create per-project session, then forward the message
        let vm = coordinator.createProjectSession(projectId: projectId) { [weak self] response in
            await self?.handleProjectResponse(projectId: projectId, response: response)
        }

        // Format message with sender attribution
        let roomLabel = message.isRoom ? " in \(message.fromContact?.name ?? contactId)" : ""
        let prompt = "[WeChat message from \(senderName) (weight: \(weight))\(roomLabel)]\n\(cleanText)"

        let history = recentHistory(for: projectId)
        let contactName = message.fromContact?.name ?? contactId

        Task {
            // Wait for session to be connected before dispatching
            let ready = await vm.waitForReady(timeout: 15)
            guard ready else {
                NSLog("[WeChatRouter] Session failed to connect for project '%@' — dropping message", projectId)
                return
            }

            // Get pending question (if any) for routing classification
            let pendingQuestion: String?
            if case .waitingForQuestions(let questions) = vm.chatState {
                pendingQuestion = questions.map(\.question).joined(separator: "; ")
            } else {
                pendingQuestion = nil
            }

            let agentState: String
            switch vm.chatState {
            case .idle: agentState = "idle"
            case .working: agentState = "working"
            case .waitingForQuestions: agentState = "waiting_for_answers"
            case .waitingForUser: agentState = "waiting_for_user"
            default: agentState = "other"
            }

            // Classify the message using routing sub-agent
            let action = await routingAgent?.classify(
                message: cleanText,
                sender: senderName,
                weight: weight,
                contactName: contactName,
                pendingQuestion: pendingQuestion,
                recentHistory: history,
                agentState: agentState
            ) ?? .newInput

            NSLog("[WeChatRouter] Classified as %@ for project '%@'", action.rawValue, projectId)

            switch action {
            case .contextOnly:
                // Store only — already logged to history above
                break

            case .resolveToolCall:
                // Message answers a pending ask_questions
                // In rooms: collect via answer constructor; in 1:1: resolve immediately
                if message.isRoom, let constructor = self.answerConstructor {
                    // Start collecting if not already
                    if !constructor.hasPending(for: projectId),
                       case .waitingForQuestions(let qs) = vm.chatState {
                        let qText = qs.map(\.question).joined(separator: "; ")
                        constructor.startCollecting(projectId: projectId, question: qText)
                    }
                    let result = await constructor.addResponse(
                        projectId: projectId,
                        sender: senderName,
                        weight: weight,
                        text: cleanText,
                        isRoom: true
                    )
                    if case .ready(let answer) = result {
                        let formatted = "[Synthesized answer from WeChat]\n\(answer)"
                        _ = await vm.sendToRelay(formatted)
                    }
                    // .waiting → do nothing, wait for more responses or timeout
                } else {
                    _ = await vm.sendToRelay(prompt)
                }

            case .newInput:
                // New instruction/request for the agent
                let state = vm.chatState
                switch state {
                case .waitingForQuestions, .waitingForUser:
                    _ = await vm.sendToRelay(prompt)
                case .working:
                    await vm.send(prompt, startAgent: false)
                default:
                    await vm.send(prompt, startAgent: true)
                }
            }
        }
    }

    /// Handle an agent response from a project session — send back to WeChat.
    func handleProjectResponse(projectId: String, response: String) async {
        let ts = ISO8601DateFormatter().string(from: Date())
        responseLog.insert("[\(ts)] project=\(projectId) len=\(response.count) text=\(String(response.prefix(100)))", at: 0)
        if responseLog.count > 10 { responseLog.removeLast() }

        guard let weChatService, let coordinator else {
            responseLog[0] += " ERR:nilRefs"
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            responseLog[0] += " ERR:empty"
            return
        }

        // Determine prefix based on project type
        let projectType = coordinator.readProjectType(projectId: projectId)
        let formatted: String
        if projectType == "wechat-assistant" {
            formatted = trimmed

            // Response-level guardrail: catch sensitive topics the agent should have held
            let incomingText = lastIncomingText[projectId] ?? ""
            let shouldHold = shouldHoldForApproval(response: trimmed, incoming: incomingText)
            if let guardrails, shouldHold {
                guard let contactId = lastActiveContact[projectId] else {
                    responseLog[0] += " ERR:noContact(guardrail)"
                    return
                }
                let approvalId = guardrails.requestApproval(
                    projectId: projectId,
                    contactId: contactId,
                    draft: trimmed,
                    reason: "Auto-detected sensitive content in response"
                )
                responseLog[0] += " HELD(approval:\(approvalId.prefix(8)))"
                NSLog("[WeChatRouter] Response held for approval: %@", approvalId)
                return
            }
        } else {
            formatted = "🤖 \(trimmed)"
        }

        guard let contactId = lastActiveContact[projectId] else {
            responseLog[0] += " ERR:noContact"
            return
        }

        NSLog("[WeChatRouter] Response → %@: %@", contactId, String(formatted.prefix(80)))
        await weChatService.sendToContact(contactId, message: formatted, watermark: true)
        responseLog[0] += " → \(contactId) OK"
    }

    /// Check if a response should be held for owner approval.
    /// Checks both the incoming message (sensitive topic?) and the response (sensitive commitment?).
    private func shouldHoldForApproval(response: String, incoming: String) -> Bool {
        let lowerResponse = response.lowercased()
        let lowerIncoming = incoming.lowercased()

        // Sensitive topic patterns — if the INCOMING message involves these, hold
        let sensitiveTopics = [
            "transfer", "转账", "汇款", "payment", "pay ", "bank account",
            "银行", "money", "dollars", "dollar", "元", "块钱",
            "schedule", "meeting", "appointment", "约", "见面",
            "address", "phone number", "id number",
            "地址", "电话", "身份证",
            "contract", "agreement", "sign", "合同", "协议",
        ]
        let incomingIsSensitive = sensitiveTopics.contains { lowerIncoming.contains($0) }

        // Response commitment patterns — if the RESPONSE agrees to something sensitive
        let commitments = [
            "i'll be there", "i will attend", "see you at", "confirmed",
            "i can meet", "let's meet", "i agree", "i accept", "deal",
            "sure, i'll", "ok, i will", "已确认", "没问题",
        ]
        let responseCommits = commitments.contains { lowerResponse.contains($0) }

        return incomingIsSensitive || responseCommits
    }

    /// Handle answer constructor timeout — force resolve with best available answer.
    private func handleTimeoutAnswer(projectId: String, answer: String) async {
        guard let coordinator else { return }
        guard let vm = coordinator.projectSessions[projectId] else { return }

        let formatted = "[Synthesized answer from WeChat (timeout)]\n\(answer)"
        _ = await vm.sendToRelay(formatted)
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
