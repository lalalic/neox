import Foundation
import Observation
import CopilotSDK
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
    private var agent: CopilotAgent?
    private var agentTask: Task<Void, Never>?
    private weak var chatVM: ChatViewModel?
    /// Continuation for answering agent's ask_user questions
    private var answerContinuation: CheckedContinuation<String, Never>?
    
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
        
        You have a manage_todo_list tool — use it for multi-step tasks to track progress.
        The todo list is displayed above the chat input in the app.
        """
        
        if webToolProvider != nil {
            prompt += "\n\n" + WebAgentToolProvider.skillPrompt
        }
        
        return prompt
    }
    
    func buildTools() -> [CopilotSDK.ToolDefinition] {
        let chatVM = self.chatVM
        var tools: [CopilotSDK.ToolDefinition] = []
        
        // Web agent tools
        if let webTools = webToolProvider?.tools {
            tools.append(contentsOf: webTools)
        }
        
        // manage_todo_list tool
        tools.append(CopilotSDK.ToolDefinition(
            name: "manage_todo_list",
            description: "Track progress on multi-step tasks. Shows a todo list above the chat input.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "todoList": .object([
                        "type": .string("array"),
                        "description": .string("Complete array of all todo items"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "id": .object(["type": .string("number"), "description": .string("Unique ID")]),
                                "title": .object(["type": .string("string"), "description": .string("Short task label")]),
                                "status": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("not-started"), .string("in-progress"), .string("completed")])
                                ])
                            ]),
                            "required": .array([.string("id"), .string("title"), .string("status")])
                        ])
                    ])
                ]),
                "required": .array([.string("todoList")])
            ]),
            skipPermission: true
        ) { args in
            guard case .object(let dict) = args,
                  case .array(let items) = dict["todoList"] else {
                return "Error: todoList array required"
            }
            let todoItems: [TodoItem] = items.compactMap { item in
                guard case .object(let obj) = item,
                      case .string(let title) = obj["title"],
                      case .string(let statusStr) = obj["status"] else { return nil }
                let id: Int
                if case .int(let i) = obj["id"] { id = i }
                else if case .double(let d) = obj["id"] { id = Int(d) }
                else { return nil }
                let status = TodoItem.TodoStatus(rawValue: statusStr) ?? .notStarted
                return TodoItem(id: id, title: title, status: status)
            }
            await MainActor.run {
                chatVM?.updateTodoList(todoItems)
            }
            let summary = todoItems.map { item in
                let icon = switch item.status {
                case .notStarted: "○"
                case .inProgress: "◐"
                case .completed: "●"
                }
                return "\(icon) \(item.title)"
            }.joined(separator: "\n")
            return "Todo list updated (\(todoItems.count) items):\n\(summary)"
        })
        
        return tools
    }
    
    /// Wire the chat view model to this coordinator.
    func wireChat(_ chatVM: ChatViewModel) {
        self.chatVM = chatVM
        chatVM.onSend = { [weak self] text in
            guard let self else { return }
            self.handleUserMessage(text)
        }
    }
    
    /// Handle a user message — either answer a pending question or start a new agent prompt.
    private func handleUserMessage(_ text: String) {
        if let continuation = answerContinuation {
            answerContinuation = nil
            continuation.resume(returning: text)
        } else {
            startAgent(prompt: text)
        }
    }
    
    /// Connect to the relay and start the agent with an initial prompt.
    func startAgent(prompt: String) {
        agentTask?.cancel()
        agentTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Connect if needed
                if self.connectionManager.state != .connected {
                    self.connectionManager.configureRelay()
                    try await self.connectionManager.connect()
                }
                
                guard let client = self.connectionManager.client else { return }
                
                self.isAgentRunning = true
                
                let chatVM = self.chatVM
                let tools = self.buildTools()
                print("[AgentCoordinator] Registering \(tools.count) tools: \(tools.map(\.name))")
                
                let agent = try await client.createAgent(config: AgentConfig(
                    model: "gpt-4.1",
                    instructions: self.buildSystemPrompt(),
                    tools: tools,
                    onResponse: { message in
                        Task { @MainActor in
                            chatVM?.receiveResponse(message)
                        }
                    },
                    onAskUser: { question in
                        await MainActor.run {
                            chatVM?.receiveQuestion(question)
                        }
                        return await withCheckedContinuation { continuation in
                            Task { @MainActor [weak self] in
                                self?.answerContinuation = continuation
                            }
                        }
                    }
                ))
                
                self.agent = agent
                self.currentSession = agent.session.sessionId
                
                try await agent.start(prompt: prompt)
            } catch {
                print("[AgentCoordinator] Error: \(error)")
            }
            
            self.isAgentRunning = false
        }
    }
    
    func stopAgent() {
        agent?.stop()
        agentTask?.cancel()
        agentTask = nil
        isAgentRunning = false
    }
}
