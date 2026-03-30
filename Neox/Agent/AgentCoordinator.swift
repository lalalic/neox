import Foundation
import Observation
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

@Observable
@MainActor
final class AgentCoordinator: ObservableObject {
    let connectionManager = ConnectionManager()
    var currentSession: String? = nil
    var isConnected: Bool { connectionManager.state == .connected }
    var registeredTools: [RegisteredTool] = []
    var isAgentRunning: Bool = false
    
    private var webToolProvider: WebAgentToolProvider?
    private let fileToolProvider = FileToolProvider()
    private var agent: CopilotAgent?
    private var agentTask: Task<Void, Never>?
    /// Reference to the shared CopilotChat view model
    private(set) var chatViewModel: ChatViewModel?
    
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
        let tools = buildTools()
        connectionManager.configureRelay()
        
        let transport = WebSocketTransport(
            host: connectionManager.host ?? "relay.ai.qili2.com",
            port: connectionManager.port ?? 443
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
            inputModes: .all
        )
        
        self.chatViewModel = vm
        return vm
    }
    
    func stopAgent() {
        chatViewModel?.disconnect()
        isAgentRunning = false
    }
}
