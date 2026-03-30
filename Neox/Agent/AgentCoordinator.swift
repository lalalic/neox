import Foundation
import CopilotSDK
import CopilotChat
import WebKitAgent

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
        return saved == 0 ? 9227 : saved
    }()

    /// Chat input mode toggles.
    @Published var enableTextInput: Bool = UserDefaults.standard.object(forKey: "enableTextInput") == nil ? true : UserDefaults.standard.bool(forKey: "enableTextInput")
    @Published var enableSpeechInput: Bool = UserDefaults.standard.object(forKey: "enableSpeechInput") == nil ? true : UserDefaults.standard.bool(forKey: "enableSpeechInput")
    @Published var enableAttachmentInput: Bool = UserDefaults.standard.object(forKey: "enableAttachmentInput") == nil ? true : UserDefaults.standard.bool(forKey: "enableAttachmentInput")
    
    private var webToolProvider: WebAgentToolProvider?
    private let fileToolProvider = FileToolProvider()
    private var agent: CopilotAgent?
    private var agentTask: Task<Void, Never>?
    /// Reference to the shared CopilotChat view model
    @Published private(set) var chatViewModel: ChatViewModel?
    
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
        ]
    }
    
    func setupWebKitAgent(manager: WebViewManager) {
        webToolProvider = WebAgentToolProvider(manager: manager)
    }
    
    func buildSystemPrompt() -> String {
        var prompt = """
        You are Neox, an autonomous AI assistant on iPhone.
        You can browse the web, take photos, speak to the user, and listen.
        Use the browser to operate websites like GitHub, Vercel, etc.
        You have file tools (read_file, write_file, list_files) to manage files in the on-device workspace.
        
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
        
        return tools
    }
    
    /// Create the shared CopilotChat view model configured for agent mode.
    func createChatViewModel() -> ChatViewModel {
        normalizeInputSettings()
        let tools = buildTools()
        
        let transport = WebSocketTransport(
            host: relayHost,
            port: relayPort
        )
        
        let vm = ChatViewModel(
            transport: transport,
            mode: .agent(AgentConfig(
                model: "gpt-4.1",
                instructions: buildSystemPrompt(),
                tools: tools,
                onResponse: { _ in },
                onAskUser: { _ in "" }
            )),
            inputModes: chatInputModes
        )
        
        self.chatViewModel = vm
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
