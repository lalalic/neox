import Foundation
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
    @Published var useLocalRelay: Bool = UserDefaults.standard.object(forKey: "useLocalRelay") == nil ? true : UserDefaults.standard.bool(forKey: "useLocalRelay")
    @Published var localRelayURL: String = UserDefaults.standard.string(forKey: "localRelayURL") ?? "http://10.0.0.111:8765"
    /// Relay server host/port currently in use.
    @Published var relayHost: String = UserDefaults.standard.string(forKey: "relayHost") ?? "10.0.0.111"
    @Published var relayPort: UInt16 = UInt16(UserDefaults.standard.integer(forKey: "relayPort")) == 0 ? 8765 : UInt16(UserDefaults.standard.integer(forKey: "relayPort"))

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

    /// Selected LLM model.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? "gpt-4.1"
    
    private var webToolProvider: WebAgentToolProvider?
    private let workspaceBootstrapper: WorkspaceBootstrapper
    private let profileLoader: AgentProfileLoader
    private let workspaceURL: URL
    private let fileToolProvider: FileToolProvider
    private let memoryToolProvider: MemoryToolProvider
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
    /// WeChat channel service (owns its own WKWebView).
    @Published private(set) var weChatService: WeChatService!

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
        self.fileToolProvider = FileToolProvider(baseDirectory: resolvedWorkspace)
        self.memoryToolProvider = MemoryToolProvider(baseDirectory: resolvedWorkspace)
        #if canImport(MediaKit)
        self.ffmpegToolProvider = FFmpegToolProvider(baseDirectory: resolvedWorkspace)
        #endif
        self.agentProfile = try? loader.load(from: resolvedWorkspace)
        self.weChatService = WeChatService(workspaceURL: resolvedWorkspace)
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
            tools.append(RegisteredTool(name: "web_agent", description: "Browser automation"))
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
            RegisteredTool(name: "create_new_project", description: "Scaffold a new project from .neo/templates/project"),
            RegisteredTool(name: "create_plan", description: "Create a scheduled plan from chat"),
            RegisteredTool(name: "stripe_checkout", description: "Generate external Stripe checkout link when requested"),
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
    
    func buildSystemPrompt() -> String {
        var prompt = """
        You are Neox, an autonomous AI assistant on iPhone.
        You can browse the web, take photos, speak to the user, and listen.
        Use the browser to operate websites like GitHub, Vercel, etc.
        You have file tools (read_file, write_file, list_files, create_new_project) to manage files in the on-device workspace.
        You have memory tools to manage long-term notes under .neo/ (memory_read, memory_append, memory_write_section, memory_log_session, memory_list).
        You have a create_plan tool to create scheduled plans directly from chat. Users can say "create a plan for X" and you create it.
        
        You have a manage_todo_list tool — use it for multi-step tasks to track progress.
        The todo list is displayed above the chat input in the app.
        """
        
        if webToolProvider != nil {
            prompt += "\n\n" + WebAgentToolProvider.skillPrompt
        }
        
        return prompt
    }
    
    func buildTools() -> [CopilotSDK.ToolDefinition] {
        var tools: [CopilotSDK.ToolDefinition] = []
        
        // Web agent tools
        if let webTools = webToolProvider?.tools {
            tools.append(contentsOf: webTools)
        }
        
        // File tools (read_file, write_file, list_files)
        tools.append(contentsOf: fileToolProvider.tools)

        // Memory tools (.neo/* memory lifecycle)
        tools.append(contentsOf: memoryToolProvider.tools)

        // Media tools (ffmpeg, ffprobe)
        #if canImport(MediaKit)
        tools.append(contentsOf: ffmpegToolProvider.tools)
        #endif
        
        return tools
    }
    
    /// Create the shared CopilotChat view model configured for agent mode.
    func createChatViewModel() -> ChatViewModel {
        normalizeInputSettings()
        let tools = buildTools()
        let hasProfileSections = !(agentProfile?.sections.isEmpty ?? true)
        let profileInstructions = agentProfile?.preambleBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = profileInstructions?.isEmpty == false ? profileInstructions! : buildSystemPrompt()
        let sections = hasProfileSections ? agentProfile?.sections : nil
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
                onResponse: { [weak self] message in
                    guard let self else { return }
                    await MainActor.run {
                        let project = self.chatViewModel?.projectScope
                        Task {
                            await self.weChatService.forward(message: message, project: project)
                        }
                    }
                },
                onAskUser: { [weak self] question in
                    guard let self else { return "" }
                    await MainActor.run {
                        let project = self.chatViewModel?.projectScope
                        Task {
                            await self.weChatService.forward(message: "❓ \(question)", project: project)
                        }
                    }
                    return ""
                }
            )),
            inputModes: chatInputModes
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
