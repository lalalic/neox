import Foundation
import UIKit
import CopilotSDK
import CopilotChat
import NeoxCore
import WebKitAgent
import Network
#if canImport(MediaKit)
import MediaKit
#endif

@MainActor
final class AgentCoordinator: BaseCoordinator {

    // MARK: - Neox-specific Properties

    @Published var channelType: String = UserDefaults.standard.string(forKey: "channelType") ?? "discord"

    /// WeChat service for forwarding messages.
    let weChatService: WeChatService
    /// Discord service for channel message forwarding.
    let discordService: DiscordService
    /// Routes incoming WeChat messages to project sessions.
    private(set) var messageRouter: WeChatMessageRouter?
    /// Thread-safe contact ID refs for guardrails tool handlers.
    private(set) var contactIdRefs: [String: ContactIdRef] = [:]

    // MARK: - Init

    override init() {
        // Initialize Neox-specific services before calling super
        // We need workspaceURL but it's set by super.init(). Use same logic:
        let bootstrapper = WorkspaceBootstrapper()
        let resolvedWorkspace: URL
        if let bootstrapped = try? bootstrapper.ensureWorkspaceReady() {
            resolvedWorkspace = bootstrapped
        } else {
            let appSupport = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            resolvedWorkspace = appSupport.appendingPathComponent("workspace", isDirectory: true)
            try? FileManager.default.createDirectory(at: resolvedWorkspace, withIntermediateDirectories: true)
        }

        self.weChatService = WeChatService(workspaceURL: resolvedWorkspace)
        self.discordService = DiscordService(workspaceURL: resolvedWorkspace)

        super.init()

        // Wire WeChat message router for bidirectional integration
        let router = WeChatMessageRouter(weChatService: weChatService, coordinator: self)
        self.messageRouter = router
        weChatService.onIncomingMessage = { [weak router] message in
            router?.route(message)
        }

        // When WeChat channel is ready, create sessions for all wired projects
        weChatService.onReady = { [weak self] in
            self?.startWiredProjectSessions()
        }

        // Wire Discord message routing
        discordService.onIncomingMessage = { [weak self] message in
            self?.handleDiscordMessage(message)
        }
    }

    // MARK: - BaseCoordinator Overrides

    override func configureChat(vm: ChatViewModel) {
        wireDiscord(to: vm)
    }

    override func reconnect() {
        saveRelaySettings()
        discordService.disconnectStandalone()
        discordService.markDisconnected()
        chatViewModel?.disconnect()
        // Reset chatViewModel via creating a new one (parent handles this)
        _ = createChatViewModel()
    }

    override func projectSessionCustomization(projectId: String) -> (instructions: String, tools: [CopilotSDK.ToolDefinition]) {
        let projectType = readProjectType(projectId: projectId)
        var extraInstructions = ""
        var extraTools: [CopilotSDK.ToolDefinition] = []

        if projectType == "wechat-assistant" {
            extraInstructions += "\nYou are acting as the account owner. Reply naturally in first person. Do not reveal you are an AI.\n"
            extraInstructions += """

            ## MANDATORY GUARDRAILS — YOU MUST FOLLOW THESE

            You have a tool called `request_approval`. You MUST call it instead of replying directly when ANY of these topics appear:
            - Money, payments, transfers, lending, bank accounts
            - Making commitments or promises on behalf of the owner (e.g., "I'll be there", "let's meet at 7pm", "I can do Tuesday")
            - Sharing personal information (address, phone, ID numbers)
            - Legal agreements, contracts, promises
            - Anything with real-world consequences beyond casual conversation

            Do NOT trigger guardrails for:
            - Casual questions about plans ("what are your dinner plans?", "are you free tonight?")
            - Informational responses about general topics
            - Simple acknowledgment or conversation

            When guardrails apply: call request_approval(draft="your proposed reply", reason="which guardrail"). Do NOT send a direct response.
            When guardrails don't apply: respond directly and naturally.

            ## Image Handling

            When you receive a message containing "[Image received — use view tool with path '...']":
            1. ALWAYS call the `view` tool with the provided path first
            2. Describe what you see in the image naturally
            3. If the sender included a caption or question, respond to that as well

            ## WeChat Response Formatting

            Use the `construct-wechat-response` skill for emoji codes, @mention rules, and formatting guidelines.
            Key rules: use [微笑] style emoji naturally, @Name for room mentions only, no markdown, match sender's language.

            """

            // Inject request_approval tool
            if let guardrails = messageRouter?.guardrails {
                let pid = projectId
                let ref = ContactIdRef()
                contactIdRefs[pid] = ref
                let tool = WeChatGuardrails.buildTool(
                    guardrails: guardrails,
                    projectId: pid,
                    contactIdRef: ref
                )
                extraTools.append(tool)
                NSLog("[AgentCoordinator] Injected request_approval tool for project '%@'", projectId)
            }
        }

        return (extraInstructions, extraTools)
    }

    /// Override saveRelaySettings to also persist Neox-specific settings.
    override func saveRelaySettings() {
        super.saveRelaySettings()
        UserDefaults.standard.set(useDevServer, forKey: "useDevServer")
        UserDefaults.standard.set(devServerPort, forKey: "devServerPort")
        UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
        UserDefaults.standard.set(showUsageInChat, forKey: "showUsageInChat")
        UserDefaults.standard.set(showProgressInChat, forKey: "showProgressInChat")
        UserDefaults.standard.set(showBuildInChat, forKey: "showBuildInChat")
        UserDefaults.standard.set(channelType, forKey: "channelType")
    }

    // MARK: - WeChat Session Lifecycle

    /// Create agent sessions for all projects that have active WeChat bindings.
    private func startWiredProjectSessions() {
        let bindings = weChatService.projectBindings
        for (projectId, binding) in bindings {
            guard binding.routingActive, !binding.contacts.isEmpty else { continue }
            guard projectSessions[projectId] == nil else { continue }
            _ = createProjectSession(projectId: projectId) { [weak self] response in
                await self?.messageRouter?.handleProjectResponse(projectId: projectId, response: response)
            }
            NSLog("[SessionLifecycle] Auto-created session for wired project '%@'", projectId)
        }
    }

    // MARK: - Discord Integration

    /// Wire DiscordService to use the relay connection.
    private func wireDiscord(to vm: ChatViewModel) {
        guard channelType == "discord" && !discordService.guildId.isEmpty else { return }

        // Always use standalone connection for Discord RPC
        Task {
            await discordService.connectStandalone(host: relayHost, port: relayPort)
        }
    }

    func rewireDiscordIfNeeded() {
        guard let vm = chatViewModel else { return }
        wireDiscord(to: vm)
    }

    private func handleDiscordMessage(_ message: DiscordService.DiscordMessage) {
        let projectId = message.projectId
        guard !projectId.isEmpty else {
            NSLog("[Discord] Message with no projectId — ignoring")
            return
        }
        guard isProjectScopeActive(for: projectId) else {
            let active = chatViewModel?.projectScope?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "none"
            NSLog("[Discord] Project '%@' not active (current: %@) — ignoring", projectId, active)
            return
        }
        NSLog("[Discord] Incoming from %@ in #%@: %@", message.senderName, message.channelName ?? message.channelId, String(message.text.prefix(60)))

        let sourceLabel = "Discord | #\(message.channelName ?? message.channelId) | \(message.senderName)"
        let prompt = "[Discord message in #\(message.channelName ?? message.channelId)]\nFrom: \(message.senderName)\n---\n\(message.text)"

        let channelId = message.channelId
        let vm = createProjectSession(projectId: projectId) { [weak self] response in
            await self?.handleDiscordResponse(projectId: projectId, channelId: channelId, response: response)
        }

        let channelName = message.channelName ?? message.channelId
        vm.onChannelQuestions = { [weak self] questionText in
            guard let self else { return }
            let formatted = "❓ **Question:**\n\(questionText)"
            let qMsg = ChatMessage(role: .assistant, content: [.text(questionText)], project: projectId, source: "Discord | #\(channelName)")
            await MainActor.run { self.chatViewModel?.mirror(qMsg) }
            do {
                try await self.discordService.sendMessage(channelId: channelId, text: formatted)
                NSLog("[Discord] Sent ask_questions to #%@ for project '%@'", channelId, projectId)
            } catch {
                NSLog("[Discord] Failed to send question: %@", error.localizedDescription)
            }
        }

        let userMsg = ChatMessage(role: .user, content: [.text(message.text)], project: projectId, source: sourceLabel)
        Task { @MainActor in chatViewModel?.mirror(userMsg) }

        Task {
            let ready = await vm.waitForReady(timeout: 15)
            guard ready else {
                NSLog("[Discord] Session failed to connect for project '%@'", projectId)
                return
            }
            await vm.channelSend(prompt, source: sourceLabel)
        }
    }

    private func handleDiscordResponse(projectId: String, channelId: String, response: String) async {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let channelName = discordService.registeredChannels.first(where: { $0.channelId == channelId })?.channelName ?? channelId
        let responseMsg = ChatMessage(role: .assistant, content: [.text(trimmed)], project: projectId, source: "Discord | #\(channelName)")
        await chatViewModel?.mirror(responseMsg)

        do {
            try await discordService.sendMessage(channelId: channelId, text: trimmed)
            NSLog("[Discord] Sent reply to #%@ (%d chars)", channelId, trimmed.count)
        } catch {
            NSLog("[Discord] Failed to send reply: %@", error.localizedDescription)
        }
    }

    // MARK: - Project Scope

    private func projectNameForId(_ projectId: String) -> String? {
        let jsonURL = workspaceRootURL.appendingPathComponent(projectId).appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: jsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["name"] as? String
    }

    func isProjectScopeActive(for projectId: String) -> Bool {
        let activeScope = chatViewModel?.projectScope?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedActive = activeScope?.lowercased()
        let normalizedProjectId = projectId.lowercased()
        let projectName = projectNameForId(projectId)?.lowercased()
        guard let normalizedActive else { return false }
        return normalizedActive == normalizedProjectId || normalizedActive == projectName
    }

    // MARK: - WeChat Project Helpers

    /// Build project tag for prompt prefix.
    func buildProjectTag(projectId: String) -> String? {
        let bindings = weChatService.getBindings(for: projectId)
        guard let first = bindings.contacts.first else { return nil }
        var parts = [first.name]
        if first.isRoom, let contact = weChatService.contacts.first(where: { $0.userName == first.id }), contact.memberCount > 0 {
            parts.append("\(contact.memberCount) members")
        }
        if let w = first.weight { parts.append("weight:\(w)") }
        return "wechat \(first.isRoom ? "room" : "individual")(\(parts.joined(separator: ", ")))"
    }

    func buildProjectSwitchSteer(projectId: String) -> String? {
        let projectDir = workspaceURL.appendingPathComponent(projectId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return nil }

        var lines: [String] = []
        lines.append("User switched to project '\(projectId)'.")

        let packageURL = projectDir.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let desc = json["description"] as? String, !desc.isEmpty {
            lines.append("Description: \(desc)")
        }

        let bindings = weChatService.getBindings(for: projectId)
        if !bindings.contacts.isEmpty {
            for contact in bindings.contacts {
                var info = "Wired to WeChat \(contact.isRoom ? "room" : "contact") '\(contact.name)'"
                if let w = contact.weight { info += " (weight: \(w))" }
                if contact.autoReply == true { info += " [auto-reply]" }
                lines.append(info)
            }
        }

        lines.append("Read the project's README.md for full context.")
        return lines.joined(separator: "\n")
    }
}
