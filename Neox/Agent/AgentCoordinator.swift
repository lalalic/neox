import Foundation
import UIKit
import CopilotSDK
import CopilotChat
import WebKitAgent
import Network
#if canImport(MediaKit)
import MediaKit
#endif

struct RegisteredTool: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let description: String
    
    static func == (lhs: RegisteredTool, rhs: RegisteredTool) -> Bool {
        lhs.name == rhs.name
    }
}

@MainActor
final class AgentCoordinator: ObservableObject {
    let connectionManager = ConnectionManager()
    @Published var currentSession: String? = nil
    var isConnected: Bool {
        guard let state = chatViewModel?.chatState else { return false }
        return state != .disconnected && state != .connecting
    }
    @Published var registeredTools: [RegisteredTool] = []
    @Published var isAgentRunning: Bool = false
    
    /// Relay toggle and endpoint settings.
    @Published var useLocalRelay: Bool = UserDefaults.standard.object(forKey: "useLocalRelay") == nil ? false : UserDefaults.standard.bool(forKey: "useLocalRelay")
    @Published var localRelayURL: String = UserDefaults.standard.string(forKey: "localRelayURL") ?? "http://10.0.0.111:8765"
    /// Relay server host/port currently in use.
    @Published var relayHost: String = UserDefaults.standard.string(forKey: "relayHost") ?? "relay.ai.qili2.com"
    @Published var relayPort: UInt16 = UInt16(UserDefaults.standard.integer(forKey: "relayPort")) == 0 ? 443 : UInt16(UserDefaults.standard.integer(forKey: "relayPort"))

    /// Dev bridge settings.
    @Published var useDevServer: Bool = UserDefaults.standard.object(forKey: "useDevServer") == nil ? true : UserDefaults.standard.bool(forKey: "useDevServer")
    @Published var devServerPort: Int = {
        let saved = UserDefaults.standard.integer(forKey: "devServerPort")
        return saved == 0 ? 9223 : saved
    }()

    /// Chat input mode toggles.
    @Published var enableTextInput: Bool = UserDefaults.standard.object(forKey: "enableTextInput") == nil ? true : UserDefaults.standard.bool(forKey: "enableTextInput")
    @Published var enableSpeechInput: Bool = UserDefaults.standard.object(forKey: "enableSpeechInput") == nil ? true : UserDefaults.standard.bool(forKey: "enableSpeechInput")
    @Published var enableAttachmentInput: Bool = UserDefaults.standard.object(forKey: "enableAttachmentInput") == nil ? true : UserDefaults.standard.bool(forKey: "enableAttachmentInput")
    @Published var channelType: String = UserDefaults.standard.string(forKey: "channelType") ?? "discord"

    /// Notification visibility in chat (which notification types show as messages).
    @Published var showUsageInChat: Bool = UserDefaults.standard.object(forKey: "showUsageInChat") == nil ? false : UserDefaults.standard.bool(forKey: "showUsageInChat")
    @Published var showProgressInChat: Bool = UserDefaults.standard.object(forKey: "showProgressInChat") == nil ? true : UserDefaults.standard.bool(forKey: "showProgressInChat")
    @Published var showBuildInChat: Bool = UserDefaults.standard.object(forKey: "showBuildInChat") == nil ? true : UserDefaults.standard.bool(forKey: "showBuildInChat")

    /// Unique device identifier for relay routing. Generated on first launch.
    @Published var neoxUserId: String = {
        if let saved = UserDefaults.standard.string(forKey: "neoxUserId"), !saved.isEmpty {
            return saved
        }
        let id = UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(String(id), forKey: "neoxUserId")
        return String(id)
    }()

    /// Selected LLM model.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? "gpt-4.1"
    
    private var webToolProvider: WebAgentToolProvider?
    private let workspaceBootstrapper: WorkspaceBootstrapper
    
    /// WeChat service for forwarding messages.
    let weChatService: WeChatService
    /// Discord service for channel message forwarding.
    let discordService: DiscordService
    /// Routes incoming WeChat messages to project sessions.
    private(set) var messageRouter: WeChatMessageRouter?
    private let profileLoader: AgentProfileLoader
    private let workspaceURL: URL
    private let fileToolProvider: FileToolProvider
    private let memoryToolProvider: MemoryToolProvider
    var memoryTools: MemoryToolProvider { memoryToolProvider }
    var fileTools: FileToolProvider { fileToolProvider }
    private let subAgentToolProvider: SubAgentToolProvider
    private let contextToolProvider: ContextToolProvider
    private let terminalToolProvider: TerminalToolProvider
    private let scriptToolProvider: ScriptToolProvider
    private let downloadToolProvider: DownloadToolProvider
    #if canImport(MediaKit)
    private let ffmpegToolProvider: FFmpegToolProvider
    #endif
    private let agentProfile: AgentRuntimeProfile?
    private var agent: CopilotAgent?
    private var agentTask: Task<Void, Never>?
    /// Reference to the shared CopilotChat view model
    @Published private(set) var chatViewModel: ChatViewModel?
    /// Payment manager for IAP credit purchases
    @Published private(set) var paymentManager: PaymentManager?
    /// Per-project sessions for WeChat bidirectional integration (projectId → ChatViewModel).
    private(set) var projectSessions: [String: ChatViewModel] = [:]
    /// Mutable response handlers per project — allows swapping callbacks without recreating sessions.
    private var projectResponseHandlers: [String: @Sendable (String) async -> Void] = [:]

    /// Number of active background watcher sessions.
    var activeWatcherCount: Int { projectSessions.count }
    /// Thread-safe contact ID refs for guardrails tool handlers.
    private(set) var contactIdRefs: [String: ContactIdRef] = [:]

    init() {
        let bootstrapper = WorkspaceBootstrapper()
        let loader = AgentProfileLoader()
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

        self.workspaceBootstrapper = bootstrapper
        self.profileLoader = loader
        self.workspaceURL = resolvedWorkspace
        self.weChatService = WeChatService(workspaceURL: resolvedWorkspace)
        self.fileToolProvider = FileToolProvider(baseDirectory: resolvedWorkspace)
        self.memoryToolProvider = MemoryToolProvider(baseDirectory: resolvedWorkspace)
        let memProvider = self.memoryToolProvider
        let fileProvider = self.fileToolProvider
        let savedPort = UserDefaults.standard.integer(forKey: "relayPort")
        let savedHost = UserDefaults.standard.string(forKey: "relayHost") ?? "relay.ai.qili2.com"
        let resolvedPort: UInt16 = savedPort > 0 ? UInt16(savedPort) : 443
        self.discordService = DiscordService(workspaceURL: resolvedWorkspace)
        let terminalProvider = TerminalToolProvider(workspaceURL: resolvedWorkspace)
        self.terminalToolProvider = terminalProvider
        self.subAgentToolProvider = SubAgentToolProvider(
            workspaceURL: resolvedWorkspace,
            relayHost: savedHost,
            relayPort: resolvedPort,
            userId: UserDefaults.standard.string(forKey: "neoxUserId"),
            toolsBuilder: {
                var tools: [ToolDefinition] = []
                tools.append(contentsOf: fileProvider.tools)
                tools.append(contentsOf: memProvider.tools)
                tools.append(contentsOf: terminalProvider.tools)
                return tools
            }
        )
        self.contextToolProvider = ContextToolProvider(workspaceURL: resolvedWorkspace)
        self.scriptToolProvider = ScriptToolProvider(workspaceURL: resolvedWorkspace, terminalProvider: terminalProvider)
        self.downloadToolProvider = DownloadToolProvider(baseDirectory: resolvedWorkspace)
        #if canImport(MediaKit)
        self.ffmpegToolProvider = FFmpegToolProvider(baseDirectory: resolvedWorkspace)
        #endif
        self.agentProfile = try? loader.load(from: resolvedWorkspace)

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

    /// Create agent sessions for all projects that have active WeChat bindings.
    /// Called when the WeChat channel becomes ready (logged in).
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

    /// Wire DiscordService to use the relay connection.
    /// If the main relay is the same as the local relay, shares the ChatViewModel WS.
    /// Otherwise, creates a standalone WS to the local relay for Discord.
    private func wireDiscord(to vm: ChatViewModel) {
        guard channelType == "discord" && !discordService.guildId.isEmpty else { return }

        let localRelay = parseLocalRelayURL()
        let mainIsLocal = relayHost == localRelay.host && relayPort == localRelay.port

        if mainIsLocal {
            // Shared mode: Discord RPCs go through the main ChatViewModel WS
            discordService.rpcSender = { [weak vm] method, params in
                guard let vm else { throw DiscordService.DiscordError.notConnected }
                return try await vm.sendRPC(method: method, params: params)
            }
            vm.onCustomNotification = { [weak self] method, params in
                self?.discordService.handleNotification(method: method, params: params)
            }
            Task {
                let ready = await vm.waitForReady(timeout: 15)
                guard ready else {
                    NSLog("[Discord] Main session not ready — skipping channel registration")
                    return
                }
                await discordService.registerBindings()
            }
        } else {
            // Standalone mode: Discord uses its own WS to local relay
            Task {
                await discordService.connectStandalone(host: localRelay.host, port: localRelay.port)
            }
        }
    }

    /// Handle an incoming Discord message — route to the bound project session.
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

        let sourceLabel = "🎮 #\(message.channelName ?? message.channelId) · \(message.senderName)"
        let prompt = "[Discord message in #\(message.channelName ?? message.channelId)]\nFrom: \(message.senderName)\n---\n\(message.text)"

        let channelId = message.channelId
        let vm = createProjectSession(projectId: projectId) { [weak self] response in
            await self?.handleDiscordResponse(projectId: projectId, channelId: channelId, response: response)
        }

        Task {
            let ready = await vm.waitForReady(timeout: 15)
            guard ready else {
                NSLog("[Discord] Session failed to connect for project '%@'", projectId)
                return
            }
            await vm.send(prompt, startAgent: true, source: sourceLabel)
        }
    }

    /// Handle an agent response from a Discord-bound project session — send back to Discord channel.
    private func handleDiscordResponse(projectId: String, channelId: String, response: String) async {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await discordService.sendMessage(channelId: channelId, text: trimmed)
            NSLog("[Discord] Sent reply to #%@ (%d chars)", channelId, trimmed.count)
        } catch {
            NSLog("[Discord] Failed to send reply: %@", error.localizedDescription)
        }
    }

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
    
    /// Save relay settings to UserDefaults.
    func saveRelaySettings() {
        normalizeInputSettings()
        UserDefaults.standard.set(relayHost, forKey: "relayHost")
        UserDefaults.standard.set(Int(relayPort), forKey: "relayPort")
        UserDefaults.standard.set(useLocalRelay, forKey: "useLocalRelay")
        UserDefaults.standard.set(localRelayURL, forKey: "localRelayURL")
        UserDefaults.standard.set(useDevServer, forKey: "useDevServer")
        UserDefaults.standard.set(devServerPort, forKey: "devServerPort")
        UserDefaults.standard.set(enableTextInput, forKey: "enableTextInput")
        UserDefaults.standard.set(enableSpeechInput, forKey: "enableSpeechInput")
        UserDefaults.standard.set(enableAttachmentInput, forKey: "enableAttachmentInput")
        UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
        UserDefaults.standard.set(showUsageInChat, forKey: "showUsageInChat")
        UserDefaults.standard.set(showProgressInChat, forKey: "showProgressInChat")
        UserDefaults.standard.set(showBuildInChat, forKey: "showBuildInChat")
        UserDefaults.standard.set(channelType, forKey: "channelType")
    }

    var chatInputModes: InputMode {
        var modes: InputMode = []
        if enableTextInput { modes.insert(.text) }
        if enableSpeechInput { modes.insert(.speech) }
        if enableAttachmentInput { modes.insert(.attachment) }
        return modes.isEmpty ? .text : modes
    }
    
    var allTools: [RegisteredTool] {
        var tools = registeredTools
        if webToolProvider != nil {
            tools.append(RegisteredTool(name: "web-agent", description: "Browser automation CLI (via run_in_terminal)"))
            tools.append(RegisteredTool(name: "site", description: "Site adapter CLI (via run_in_terminal)"))
        }
        return tools
    }
    
    func registerDefaultTools() {
        registeredTools = [
            RegisteredTool(name: "speak", description: "Read text aloud to user"),
            RegisteredTool(name: "listen", description: "Listen for voice input"),
            RegisteredTool(name: "notify", description: "Send local notification"),
            RegisteredTool(name: "take_photo", description: "Capture photo with camera"),
            RegisteredTool(name: "copy_to_clipboard", description: "Copy text to clipboard"),
            RegisteredTool(name: "memory_read", description: "Read memory notes under .neo"),
            RegisteredTool(name: "memory_append", description: "Append timestamped memory notes"),
            RegisteredTool(name: "memory_write_section", description: "Write/replace memory markdown sections"),
            RegisteredTool(name: "memory_log_session", description: "Create session notes in .neo/reports/sessions"),
            RegisteredTool(name: "memory_list", description: "List memory files under .neo"),
            RegisteredTool(name: "create_project", description: "Scaffold a new project from .templates/projects/"),
            RegisteredTool(name: "run_in_terminal", description: "Execute shell commands on device (ls, grep, curl, etc.)"),
            RegisteredTool(name: "run_script", description: "Execute JavaScript code on device (loops, JSON, data processing)"),
            RegisteredTool(name: "start_coding_task", description: "Start coding task: create GitHub repo, issue, assign coding agent"),
            RegisteredTool(name: "send_response", description: "Send a response message to the user"),
            RegisteredTool(name: "create_plan", description: "Create a scheduled plan from chat"),
            RegisteredTool(name: "stripe_checkout", description: "Generate external Stripe checkout link when requested"),
            RegisteredTool(name: "run_sub_agent", description: "Run a named sub-agent in a separate session"),
            RegisteredTool(name: "get_context", description: "Get device context: time, battery, network, projects"),
            RegisteredTool(name: "memory_search", description: "Search across memory files by keyword"),
            RegisteredTool(name: "memory_delete", description: "Delete a memory file or section"),
            RegisteredTool(name: "memory_get_yesterday", description: "Get yesterday's daily summary"),
        ]
        #if canImport(MediaKit)
        registeredTools.append(contentsOf: [
            RegisteredTool(name: "ffmpeg", description: "Run ffmpeg media processing commands"),
            RegisteredTool(name: "ffprobe", description: "Inspect media metadata and streams"),
        ])
        #endif
    }
    
    func setupWebKitAgent(manager: WebViewManager) {
        webToolProvider = WebAgentToolProvider(manager: manager)

        // Register web-agent as a CLI command in terminal
        if let webProvider = webToolProvider {
            terminalToolProvider.registerCommand(name: "web-agent") { [weak webProvider] command in
                guard let provider = webProvider else { return "Error: web-agent not available" }
                return try await provider.handleCLI(command)
            }

            // Register site as a standalone CLI command for site adapters
            terminalToolProvider.registerCommand(name: "site") { [weak webProvider] command in
                guard let provider = webProvider else { return "Error: site adapters not available" }
                // Strip "site " prefix — handleSiteCLI expects "<site> <action> [key=val ...]"
                let args = command.drop(while: { !$0.isWhitespace }).drop(while: { $0.isWhitespace })
                return try await provider.handleSiteCLI(String(args))
            }

            // Wire file converter to ChatViewModel for convert_to_markdown
            chatViewModel?.fileConverter = { @Sendable [weak webProvider] filePath, format in
                guard let provider = webProvider else {
                    throw NSError(domain: "AgentCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Web agent not available"])
                }
                return try await provider.convertFile(filePath: filePath, outputFormat: format)
            }
        }
    }

    var mainAgentFileURL: URL {
        workspaceURL
            .appendingPathComponent(".github", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("main.agent.md")
    }

    /// The root URL of the on-device workspace (for file explorer, etc.)
    var workspaceRootURL: URL {
        workspaceURL
    }
    
    /// Check if a notification type should be shown in the chat UI.
    func shouldShowNotificationInChat(type: String) -> Bool {
        switch type {
        case "usage": return showUsageInChat
        case "agent_progress": return showProgressInChat
        case "build_complete", "build_failed": return showBuildInChat
        default: return true
        }
    }
    
    func buildTools() -> [CopilotSDK.ToolDefinition] {
        var tools: [CopilotSDK.ToolDefinition] = []
        
        // File tools (read_file, write_file, list_files)
        tools.append(contentsOf: fileToolProvider.tools)

        // Memory tools (.neo/* memory lifecycle)
        tools.append(contentsOf: memoryToolProvider.tools)

        // Sub-agent tools (run_sub_agent)
        tools.append(contentsOf: subAgentToolProvider.tools)

        // Context tools (get_context)
        tools.append(contentsOf: contextToolProvider.tools)

        // Terminal tools (run_in_terminal via ios_system)
        tools.append(contentsOf: terminalToolProvider.tools)

        // Script tools (run_script via JavaScriptCore)
        tools.append(contentsOf: scriptToolProvider.tools)

        // Download tools (download_file via URLSession)
        tools.append(contentsOf: downloadToolProvider.tools)

        // Media tools (ffmpeg, ffprobe)
        #if canImport(MediaKit)
        tools.append(contentsOf: ffmpegToolProvider.tools)
        #endif
        
        return tools
    }
    
    /// Build a tree string of the workspace folder structure (3 levels deep).
    /// Excludes node_modules, .git, build artifacts.
    private func buildDeviceContext() -> String {
        let device = UIDevice.current
        let screen = UIScreen.main
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let timeOfDay: String
        switch hour {
        case 6..<10: timeOfDay = "morning"
        case 10..<14: timeOfDay = "midday"
        case 14..<18: timeOfDay = "afternoon"
        case 18..<22: timeOfDay = "evening"
        default: timeOfDay = "night"
        }
        let weekdayFmt = DateFormatter()
        weekdayFmt.dateFormat = "EEEE"

        device.isBatteryMonitoringEnabled = true
        let batteryLevel = device.batteryLevel >= 0 ? "\(Int(device.batteryLevel * 100))%" : "unknown"
        let batteryState: String
        switch device.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "unplugged"
        default: batteryState = "unknown"
        }

        let preferredLang = Locale.preferredLanguages.first ?? "en"
        let regionCode = Locale.current.region?.identifier ?? "unknown"

        // Storage info
        let storage: String
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           let totalBytes = attrs[.systemSize] as? Int64 {
            let freeGB = Double(freeBytes) / 1_073_741_824
            let totalGB = Double(totalBytes) / 1_073_741_824
            storage = String(format: "%.1fGB free / %.0fGB total", freeGB, totalGB)
        } else {
            storage = "unknown"
        }

        // Network status from contextToolProvider
        let network = contextToolProvider.currentNetworkStatus

        return """
        * Device: \(device.model) (\(device.name))
        * OS: \(device.systemName) \(device.systemVersion)
        * Screen: \(Int(screen.bounds.width))x\(Int(screen.bounds.height))pt @\(Int(screen.scale))x
        * Storage: \(storage)
        * Battery: \(batteryLevel) (\(batteryState))
        * Network: \(network)
        * Language: \(preferredLang), Region: \(regionCode)
        * Time: \(fmt.string(from: now))
        * Day: \(weekdayFmt.string(from: now)), \(timeOfDay)
        * Timezone: \(TimeZone.current.identifier)
        """
    }

    private func buildWorkspaceTree() -> String {
        let fm = FileManager.default
        let excludes: Set<String> = ["node_modules", ".git", "build", "build-sim", "build-device", ".build"]
        
        func listDir(_ url: URL, prefix: String, depth: Int) -> String {
            guard depth > 0 else { return "" }
            guard let contents = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter({ !excludes.contains($0.lastPathComponent) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return "" }
            
            // Also include dotfiles we care about
            let dotContents = (try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
            ).filter({ $0.lastPathComponent.hasPrefix(".") && !excludes.contains($0.lastPathComponent) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })) ?? []
            
            let allItems = (dotContents + contents).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            // Deduplicate
            var seen = Set<String>()
            let unique = allItems.filter { seen.insert($0.lastPathComponent).inserted }
            
            var result = ""
            for item in unique {
                let name = item.lastPathComponent
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                result += "\(prefix)\(name)\(isDir ? "/" : "")\n"
                if isDir {
                    result += listDir(item, prefix: prefix + "  ", depth: depth - 1)
                }
            }
            return result
        }
        
        return listDir(workspaceURL, prefix: "", depth: 3)
    }
    
    /// Build a description of available project templates from .templates/projects/.
    /// Reads each template's README.md for frontmatter name/description.
    private func buildTemplateInfo() -> String {
        let fm = FileManager.default
        let templatesDir = workspaceURL
            .appendingPathComponent(".templates", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        
        guard let templates = try? fm.contentsOfDirectory(
            at: templatesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter({
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return ""
        }
        
        var lines: [String] = ["## project templates", "Read the template's README.md before creating a new project.", ""]
        lines.append("| Template | Description |")
        lines.append("|----------|-------------|")
        
        for template in templates {
            let name = template.lastPathComponent
            let readmeURL = template.appendingPathComponent("README.md")
            var description = ""
            if let content = try? String(contentsOf: readmeURL, encoding: .utf8) {
                // Extract first # goal section content
                let lines = content.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    if line.lowercased().hasPrefix("# goal") && i + 1 < lines.count {
                        description = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
            if description.isEmpty { description = name }
            lines.append("| `\(name)` | \(description) |")
        }
        
        return lines.joined(separator: "\n")
    }

    /// Create the shared CopilotChat view model configured for agent mode.
    func createChatViewModel() -> ChatViewModel {
        normalizeInputSettings()
        let tools = buildTools()
        var instructions = agentProfile?.preambleBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Inject dynamic workspace context
        let tree = buildWorkspaceTree()
        if !tree.isEmpty {
            instructions += "\n\n## current workspace files\n```\n\(tree)```"
        }
        let templateInfo = buildTemplateInfo()
        if !templateInfo.isEmpty {
            instructions += "\n\n\(templateInfo)"
        }
        // Inject discovered on-device skills into the system prompt
        if let skills = agentProfile?.skills,
           let skillSection = SkillDiscovery.buildPromptSection(from: skills) {
            instructions += "\n\n\(skillSection)"
        }
        var sections = agentProfile?.sections ?? [:]
        // Inject device/environment context into the proper section
        sections["environment_context"] = .replace(content: buildDeviceContext())
        // Enforce concise responses for mobile context
        let mobileTone = "You are on a mobile device with a small screen. Keep responses concise — 1-3 sentences for simple answers. Use bullet points for lists. Avoid unnecessary introductions, conclusions, and filler. Do not repeat the user's question back."
        if let existing = sections["tone"] {
            if case .replace(content: let content) = existing {
                sections["tone"] = .replace(content: content + "\n" + mobileTone)
            } else {
                sections["tone"] = .append(content: mobileTone)
            }
        } else {
            sections["tone"] = .append(content: mobileTone)
        }
        let finalSections: [String: SystemMessageSectionAction]? = sections.isEmpty ? nil : sections
        let model = selectedModel
        
        let transport = WebSocketTransport(
            host: relayHost,
            port: relayPort
        )
        
        let vm = ChatViewModel(
            transport: transport,
            mode: .agent(AgentConfig(
                model: model,
                instructions: instructions,
                sections: finalSections,
                tools: tools,
                appId: "neox",
                deviceToken: UserDefaults.standard.string(forKey: "apnsDeviceToken"),
                apnsEnv: {
                    #if DEBUG
                    return "sandbox"
                    #else
                    return "production"
                    #endif
                }(),
                userId: neoxUserId,
                onResponse: { _ in },
                onAskUser: { _ in "" }
            )),
            inputModes: chatInputModes,
            workspaceURL: workspaceURL,
            notificationFilter: { [weak self] type in
                guard let self else { return true }
                switch type {
                case "usage": return self.showUsageInChat
                case "agent_progress": return self.showProgressInChat
                case "build_complete", "build_failed": return self.showBuildInChat
                default: return true
                }
            }
        )
        
        self.chatViewModel = vm
        self.paymentManager = PaymentManager(usageTracker: vm.usageTracker)

        // Wire Discord to use shared WS connection
        wireDiscord(to: vm)

        Task { await vm.connect() }
        return vm
    }
    
    /// Reconnect with new relay settings.
    func reconnect() {
        applyRelaySelection()
        saveRelaySettings()
        discordService.disconnectStandalone()
        discordService.markDisconnected()
        chatViewModel?.disconnect()
        chatViewModel = nil
        _ = createChatViewModel()
    }
    
    func stopAgent() {
        chatViewModel?.disconnect()
        isAgentRunning = false
    }

    // MARK: - Per-Project Sessions (WeChat Bidirectional)

    /// Create a dedicated agent session for a wired project.
    /// The session is headless — no chat UI. Messages come from WeChat, responses go back to WeChat.
    func createProjectSession(projectId: String, onResponse: @escaping @Sendable (String) async -> Void) -> ChatViewModel {
        // Always update the response handler — even for existing sessions.
        projectResponseHandlers[projectId] = onResponse
        if let existing = projectSessions[projectId] { return existing }

        let transport = WebSocketTransport(host: relayHost, port: relayPort)

        // Load project context (README.md, context.md, memory.md) for instructions
        let projectDir = workspaceURL.appendingPathComponent(projectId, isDirectory: true)
        var projectContext = "You are a project assistant for '\(projectId)'.\n"
        let readmePath = projectDir.appendingPathComponent("README.md")
        let contextPath = projectDir.appendingPathComponent("context.md")
        let memoryPath = projectDir.appendingPathComponent("memory.md")
        if let readme = try? String(contentsOf: readmePath, encoding: .utf8), !readme.isEmpty {
            projectContext += "\n## Project README\n\(readme)\n"
        }
        if let ctx = try? String(contentsOf: contextPath, encoding: .utf8), !ctx.isEmpty {
            projectContext += "\n## Context\n\(ctx)\n"
        }
        if let memory = try? String(contentsOf: memoryPath, encoding: .utf8), !memory.isEmpty {
            projectContext += "\n## Project Memory\n\(memory)\n"
        }

        let projectType = readProjectType(projectId: projectId)
        if projectType == "wechat-assistant" {
            projectContext += "\nYou are acting as the account owner. Reply naturally in first person. Do not reveal you are an AI.\n"
            projectContext += """
            
            ## MANDATORY GUARDRAILS — YOU MUST FOLLOW THESE
            
            You have a tool called `request_approval`. You MUST call it instead of replying directly when ANY of these topics appear:
            - Money, payments, transfers, lending, bank accounts
            - Scheduling meetings, appointments, commitments on behalf of the owner
            - Sharing personal information (address, phone, ID numbers)
            - Legal agreements, contracts, promises
            - Anything with real-world consequences beyond casual conversation
            
            When guardrails apply: call request_approval(draft="your proposed reply", reason="which guardrail"). Do NOT send a direct response.
            When guardrails don't apply: respond directly and naturally.
            
            ## WeChat Response Formatting
            
            Use the `construct-wechat-response` skill for emoji codes, @mention rules, and formatting guidelines.
            Key rules: use [微笑] style emoji naturally, @Name for room mentions only, no markdown, match sender's language.
            
            """
        } else {
            projectContext += "\nYou are a project assistant. Be helpful and concise.\n"
        }
        projectContext += "\nKeep responses under 3 sentences unless the question requires a detailed answer. Match the language of the sender."
        projectContext += "\nUse memory tools with path '\(projectId)/memory.md' to remember project-specific info (contacts, preferences, key facts). Read it at session start."
        projectContext += "\nIMPORTANT: This is a headless session with no interactive user. Do NOT call ask_questions. Just provide your best response directly."

        var tools = buildTools()
        // Inject request_approval tool for wechat-assistant projects
        if projectType == "wechat-assistant", let guardrails = messageRouter?.guardrails {
            let pid = projectId
            let ref = ContactIdRef()
            contactIdRefs[pid] = ref
            let tool = WeChatGuardrails.buildTool(
                guardrails: guardrails,
                projectId: pid,
                contactIdRef: ref
            )
            tools.append(tool)
            NSLog("[AgentCoordinator] Injected request_approval tool for project '%@' (total tools: %d)", projectId, tools.count)
        } else {
            NSLog("[AgentCoordinator] No guardrails injection for project '%@' (type: %@, guardrails: %@)", projectId, projectType ?? "nil", messageRouter?.guardrails == nil ? "nil" : "ok")
        }
        let model = selectedModel

        let vm = ChatViewModel(
            transport: transport,
            mode: .agent(AgentConfig(
                model: model,
                instructions: projectContext,
                tools: tools,
                appId: "neox-wc-\(projectId)",
                deviceToken: UserDefaults.standard.string(forKey: "apnsDeviceToken"),
                apnsEnv: {
                    #if DEBUG
                    return "sandbox"
                    #else
                    return "production"
                    #endif
                }(),
                userId: neoxUserId,
                onResponse: { [weak self] response in
                    // Trampoline: look up the current handler so it can be swapped at runtime.
                    let handler = await MainActor.run { self?.projectResponseHandlers[projectId] }
                    await handler?(response)
                },
                onAskUser: { _ in "" }
            )),
            workspaceURL: workspaceURL
        )

        projectSessions[projectId] = vm
        vm.skipPendingRestore = true
        Task { await vm.connect() }
        NSLog("[AgentCoordinator] Created project session for '%@' (type: %@, appId: neox-wc-%@)", projectId, projectType ?? "unknown", projectId)
        return vm
    }

    /// Destroy a project session (e.g., when unwiring from WeChat).
    func destroyProjectSession(projectId: String) {
        guard let vm = projectSessions.removeValue(forKey: projectId) else { return }
        projectResponseHandlers.removeValue(forKey: projectId)
        vm.disconnect()
        print("[AgentCoordinator] Destroyed project session for '\(projectId)'")
    }

    /// Read the projectType from a project's package.json.
    func readProjectType(projectId: String) -> String? {
        let packageURL = workspaceURL
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["projectType"] as? String else {
            return nil
        }
        return type
    }

    /// Build project tag for prompt prefix.
    /// e.g. "wechat room(devteam, 80 members, weight:80)" or "wechat individual(Claire, weight:50)"
    /// Returns nil if project has no WeChat wiring.
    func buildProjectTag(projectId: String) -> String? {
        let bindings = weChatService.getBindings(for: projectId)
        guard let first = bindings.contacts.first else { return nil }
        var parts = [first.name]
        // Add member count for rooms
        if first.isRoom, let contact = weChatService.contacts.first(where: { $0.userName == first.id }), contact.memberCount > 0 {
            parts.append("\(contact.memberCount) members")
        }
        if let w = first.weight { parts.append("weight:\(w)") }
        return "wechat \(first.isRoom ? "room" : "individual")(\(parts.joined(separator: ", ")))"
    }

    /// Build a lightweight steer message for when user switches to a project.
    /// The agent should self-discover project details by reading files.
    func buildProjectSwitchSteer(projectId: String) -> String? {
        let projectDir = workspaceURL.appendingPathComponent(projectId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: projectDir.path) else { return nil }

        var lines: [String] = []
        lines.append("User switched to project '\(projectId)'.")

        // Description from package.json
        let packageURL = projectDir.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let desc = json["description"] as? String, !desc.isEmpty {
            lines.append("Description: \(desc)")
        }

        // Wired WeChat contact info
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

    /// Run a named sub-agent (from .github/agents/) programmatically.
    /// Used by WeChatRoutingAgent and WeChatAnswerConstructor.
    func runSubAgent(name: String, task: String, model: String? = nil) async -> String {
        return await subAgentToolProvider.runAgent(name: name, task: task, model: model)
    }

    private func normalizeInputSettings() {
        if !enableTextInput && !enableSpeechInput && !enableAttachmentInput {
            enableTextInput = true
        }
    }

    func applyRelaySelection() {
        if useLocalRelay {
            if let parsed = parseRelayURL(localRelayURL) {
                relayHost = parsed.host
                relayPort = parsed.port
            } else {
                relayHost = "10.0.0.111"
                relayPort = 8765
                localRelayURL = "http://10.0.0.111:8765"
            }
        } else {
            relayHost = "relay.ai.qili2.com"
            relayPort = 443
        }
    }

    private func parseRelayURL(_ raw: String) -> (host: String, port: UInt16)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: withScheme), let host = url.host else { return nil }
        let port = UInt16(url.port ?? 8765)
        return (host, port)
    }

    /// Parse localRelayURL into host/port for external use (e.g. DiscordService).
    func parseLocalRelayURL() -> (host: String, port: UInt16) {
        parseRelayURL(localRelayURL) ?? ("10.0.0.111", 8765)
    }
}
