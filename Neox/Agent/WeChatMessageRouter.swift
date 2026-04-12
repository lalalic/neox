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
    private let speechTranscriber = SpeechTranscriber()

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

        // Channel exclusivity: only route if global channel is wechat
        guard coordinator.channelType == "wechat" else {
            NSLog("[WeChatRouter] Channel type is '%@' — ignoring WeChat message", coordinator.channelType)
            return
        }

        // Look up which project this contact is bound to
        let contactId = message.routingContactId
        guard let projectId = weChatService.projectForContact(contactId) else {
            return
        }

        guard coordinator.isProjectScopeActive(for: projectId) else {
            let active = coordinator.chatViewModel?.projectScope ?? "none"
            NSLog("[WeChatRouter] Project '%@' not active (current: %@) — ignoring", projectId, active)
            return
        }

        // Process message based on type
        let messageText: String
        var savedMediaPath: String? = nil

        switch message.msgType {
        case 1:
            messageText = message.content
        case 34:
            // Voice message — save and transcribe
            let duration = message.voiceLength.map { "\($0)s" } ?? "unknown duration"
            if let base64 = message.voiceBase64, !base64.isEmpty {
                let path = saveMedia(base64: base64, ext: "mp3", projectId: projectId)
                savedMediaPath = path
                if let path {
                    // Kick off async transcription — will update message after transcription completes
                    let fileURL = coordinator.workspaceRootURL.appendingPathComponent(path)
                    let transcriber = self.speechTranscriber
                    Task {
                        let transcription = await transcriber.transcribe(fileURL: fileURL)
                        if let transcription, !transcription.isEmpty {
                            NSLog("[WeChatRouter] Voice transcribed: %@", String(transcription.prefix(80)))
                            // Re-route with transcribed text
                            let updatedText = "[Voice message (\(duration)): \"\(transcription)\"]"
                            self.updateLastIncoming(projectId: projectId, text: updatedText)
                            // Send transcription to the active session
                            if let vm = self.coordinator?.projectSessions[projectId] {
                                let prompt = "[Voice transcription from \(message.fromContact?.name ?? message.fromUserName)]\n\(transcription)"
                                await vm.send(prompt, startAgent: true)
                            }
                        } else {
                            NSLog("[WeChatRouter] Voice transcription failed for %@", path)
                        }
                    }
                    messageText = "[Voice message (\(duration)) — transcribing...]"
                } else {
                    messageText = "[Voice message (\(duration)) — save failed]"
                }
            } else {
                messageText = "[Voice message (\(duration))]"
            }
        case 3:
            // Image message — save and tell agent to view it
            if let base64 = message.imageBase64, !base64.isEmpty {
                let path = saveMedia(base64: base64, ext: "jpg", projectId: projectId)
                savedMediaPath = path
                if let path {
                    messageText = "[Image received — use view tool with path '\(path)' to see it]"
                } else {
                    messageText = "[Image received but failed to save]"
                }
            } else {
                messageText = "[Image received but not downloaded]"
            }
        case 49:
            // App message (file, link, mini-program)
            messageText = formatAppMessage(message)
        default:
            return
        }

        // Get sender info — use JS-parsed senderContact for rooms
        let senderName: String
        let senderId: String
        if message.isRoom {
            senderId = message.senderContact?.userName ?? "unknown"
            senderName = message.senderContact?.name ?? senderId
        } else {
            senderId = message.fromUserName
            senderName = message.fromContact?.name ?? senderId
        }

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
            text: messageText,
            weight: weight,
            projectId: projectId,
            contactId: contactId,
            isRoom: message.isRoom
        )
        appendToHistory(entry, projectId: projectId)

        // Track which contact triggered this for response routing
        lastActiveContact[projectId] = contactId
        lastIncomingText[projectId] = messageText
        // Update thread-safe ref for guardrails tool handler
        coordinator.contactIdRefs[projectId]?.value = contactId

        NSLog("[WeChatRouter] %@ (w:%d) → project '%@': %@", senderName, weight, projectId, String(messageText.prefix(80)))

        // Get or create per-project session, then forward the message
        let vm = coordinator.createProjectSession(projectId: projectId) { [weak self] response in
            await self?.handleProjectResponse(projectId: projectId, response: response)
        }

        // Set up ask_questions forwarding to WeChat
        vm.onChannelQuestions = { [weak self] questionText in
            guard let self, let ws = self.weChatService, let coord = self.coordinator else { return }
            let activeContact = self.lastActiveContact[projectId] ?? contactId
            let formatted = "❓ \(questionText)"
            // Mirror question to main chat
            let qMsg = ChatMessage(role: .assistant, content: [.text(questionText)], project: projectId, source: "WeChat | \(senderName)")
            await MainActor.run { coord.chatViewModel?.mirror(qMsg) }
            await ws.sendToContact(activeContact, message: formatted, watermark: true)
            NSLog("[WeChatRouter] Sent ask_questions to %@ for project '%@'", activeContact, projectId)
        }

        // Format message with rich context for the agent
        let prompt: String
        let sourceLabel: String
        if message.isRoom {
            let roomName = message.fromContact?.name ?? weChatService.contactDisplayName(contactId, project: projectId) ?? contactId
            sourceLabel = "WeChat | \(roomName) | \(senderName)"
            var lines = ["[WeChat message in \(roomName)]"]
            lines.append("From: \(senderName) (weight: \(weight))")
            if message.mentionMe {
                lines.append("@mentioned you: yes")
            }
            if !message.mentions.isEmpty {
                let mentionedNames = message.mentions.joined(separator: ", ")
                lines.append("Mentioned: \(mentionedNames)")
            }
            lines.append("---")
            lines.append(messageText)
            prompt = lines.joined(separator: "\n")
        } else {
            sourceLabel = "WeChat | \(senderName)"
            prompt = "[WeChat message from \(senderName) (weight: \(weight))]\n\(messageText)"
        }

        // Mirror user message to main chat for visibility
        let userMsg = ChatMessage(role: .user, content: [.text(messageText)], project: projectId, source: sourceLabel)
        Task { @MainActor in coordinator.chatViewModel?.mirror(userMsg) }

        let history = recentHistory(for: projectId)
        let contactName = message.fromContact?.name ?? weChatService.contactDisplayName(contactId, project: projectId) ?? contactId

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
                message: messageText,
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
                        text: messageText,
                        isRoom: true
                    )
                    if case .ready(let answer) = result {
                        let formatted = "[Synthesized answer from WeChat]\n\(answer)"
                        _ = await vm.sendToRelay(formatted, source: sourceLabel)
                    }
                    // .waiting → do nothing, wait for more responses or timeout
                } else {
                    _ = await vm.sendToRelay(prompt, source: sourceLabel)
                }

            case .newInput:
                // New instruction/request — channelSend routes by state
                await vm.channelSend(prompt, source: sourceLabel)
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

        // Mirror response to main chat for visibility
        let contactName = weChatService.contactDisplayName(contactId, project: projectId) ?? contactId
        let respSource = "WeChat | \(contactName)"
        let responseMsg = ChatMessage(role: .assistant, content: [.text(trimmed)], project: projectId, source: respSource)
        Task { @MainActor in coordinator.chatViewModel?.mirror(responseMsg) }

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

    // MARK: - Media Helpers

    /// Save base64-encoded media data to the project's media directory.
    /// Returns the workspace-relative path (e.g. "projectId/media/img-1234.jpg").
    private func saveMedia(base64: String, ext: String, projectId: String) -> String? {
        guard let coordinator else { return nil }
        let fm = FileManager.default
        let mediaDir = coordinator.workspaceRootURL
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(ext)-\(timestamp).\(ext)"
        let fileURL = mediaDir.appendingPathComponent(filename)

        guard let data = Data(base64Encoded: base64) else {
            NSLog("[WeChatRouter] Failed to decode base64 media for project '%@'", projectId)
            return nil
        }

        do {
            try data.write(to: fileURL)
            let relativePath = "\(projectId)/media/\(filename)"
            NSLog("[WeChatRouter] Saved media: %@ (%d bytes)", relativePath, data.count)
            return relativePath
        } catch {
            NSLog("[WeChatRouter] Failed to save media: %@", error.localizedDescription)
            return nil
        }
    }

    /// Update the last incoming text for a project (used when voice transcription completes async).
    private func updateLastIncoming(projectId: String, text: String) {
        lastIncomingText[projectId] = text
    }

    /// Format an app message (msgType 49) with extracted title/desc/url.
    private func formatAppMessage(_ message: WeChatMessage) -> String {
        var parts: [String] = []

        if let title = message.appTitle, !title.isEmpty {
            parts.append("Title: \(title)")
        }
        if let desc = message.appDesc, !desc.isEmpty {
            parts.append("Description: \(desc)")
        }
        if let url = message.appUrl, !url.isEmpty {
            parts.append("URL: \(url)")
        }

        if parts.isEmpty {
            return "[Shared link or file]"
        }

        let appTypeLabel: String
        switch message.appType {
        case 5: appTypeLabel = "Link"
        case 6: appTypeLabel = "File"
        case 33, 36: appTypeLabel = "Mini Program"
        default: appTypeLabel = "Shared content"
        }

        return "[\(appTypeLabel)]\n\(parts.joined(separator: "\n"))"
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
