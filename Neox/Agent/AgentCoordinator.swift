import Foundation
import UIKit
import CopilotSDK
import CopilotChat
import WebKitAgent
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
    var isConnected: Bool { connectionManager.state == .connected }
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
        let terminalProvider = TerminalToolProvider(workspaceURL: resolvedWorkspace)
        self.terminalToolProvider = terminalProvider
        self.subAgentToolProvider = SubAgentToolProvider(
            workspaceURL: resolvedWorkspace,
            relayHost: UserDefaults.standard.string(forKey: "relayHost") ?? "relay.ai.qili2.com",
            relayPort: savedPort > 0 ? UInt16(savedPort) : 443,
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

        return """
        ## device
        - Model: \(device.model) (\(device.name))
        - OS: \(device.systemName) \(device.systemVersion)
        - Screen: \(Int(screen.bounds.width))x\(Int(screen.bounds.height))pt @\(Int(screen.scale))x
        - Battery: \(batteryLevel) (\(batteryState))

        ## current time
        - \(fmt.string(from: now))
        - \(weekdayFmt.string(from: now)), \(timeOfDay)
        - Timezone: \(TimeZone.current.identifier)
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
        
        // Inject device context
        instructions += "\n\n\(buildDeviceContext())"

        // Inject dynamic workspace context
        let tree = buildWorkspaceTree()
        if !tree.isEmpty {
            instructions += "\n\n## current workspace files\n```\n\(tree)```"
        }
        let templateInfo = buildTemplateInfo()
        if !templateInfo.isEmpty {
            instructions += "\n\n\(templateInfo)"
        }
        let sections = (agentProfile?.sections.isEmpty ?? true) ? nil : agentProfile?.sections
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
                sections: sections,
                tools: tools,
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
        Task { await vm.connect() }
        return vm
    }
    
    /// Reconnect with new relay settings.
    func reconnect() {
        applyRelaySelection()
        saveRelaySettings()
        chatViewModel?.disconnect()
        chatViewModel = nil
        let vm = createChatViewModel()
        Task { await vm.connect() }
    }
    
    func stopAgent() {
        chatViewModel?.disconnect()
        isAgentRunning = false
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
}
