import SwiftUI
import AppAgent
import Observation

@Observable
@MainActor
final class AppAgentSetup {
    static let shared = AppAgentSetup()
    
    private var server: MCPServer?
    private var toolProvider: AppAgentToolProvider?
    private var bridgeHandlers: [String: (AppAgent.JSONValue) async throws -> String] = [:]
    private var bridgeToolList: [[String: Any]] = []
    private(set) var port: UInt16 = 9223
    var startError: String?
    var serverState: String = "idle"
    var bridgeState: String = "off"
    weak var chatViewModel: ChatViewModel?
    weak var coordinator: AgentCoordinator?
    private var bridgeTask: Task<Void, Never>?
    
    private init() {}
    
    func start(port: UInt16 = 9223) throws {
        self.port = port
        self.serverState = "starting"
        let server = MCPServer(name: "neox", port: port)
        let provider = AppAgentToolProvider()
        
        // Register tools and keep handlers for bridge
        for tool in provider.tools {
            server.register(tools: [tool])
            bridgeHandlers[tool.name] = tool.handler
            bridgeToolList.append([
                "name": tool.name,
                "description": tool.description ?? "",
                "inputSchema": ["type": "object"]
            ])
        }
        registerChatTools(server: server)
        try server.start()
        
        self.server = server
        self.toolProvider = provider
        
        // Monitor isRunning state changes
        Task { @MainActor in
            for delay in [0.5, 1.0, 2.0, 5.0] {
                try? await Task.sleep(for: .seconds(delay))
                if server.isRunning {
                    self.serverState = "running"
                    return
                }
            }
            if !server.isRunning {
                self.serverState = "failed (listener never ready)"
            }
        }
    }
    
    func stop() {
        server?.stop()
        server = nil
        toolProvider = nil
    }
    
    var isRunning: Bool {
        server?.isRunning ?? false
    }
    
    // MARK: - Chat Tools
    
    private func registerChatTools(server: MCPServer) {
        let sendMessageHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] args in
            let text: String
            if case .object(let dict) = args, case .string(let t) = dict["text"] {
                text = t
            } else {
                return "Error: 'text' parameter required"
            }
            let result = await MainActor.run { [weak self] () -> String? in
                guard let chatVM = self?.chatViewModel else { return nil }
                chatVM.inputText = text
                return "ok"
            }
            guard result != nil else { return "Error: chatViewModel not wired" }
            await MainActor.run { [weak self] in
                guard let chatVM = self?.chatViewModel else { return }
                Task { await chatVM.send() }
            }
            return "Message sent: \(text)"
        }
        
        server.register(
            name: "send_message",
            description: "Send a chat message as the user. Triggers the agent pipeline.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The message text to send"]
                ],
                "required": ["text"]
            ],
            handler: sendMessageHandler
        )
        bridgeHandlers["send_message"] = sendMessageHandler
        bridgeToolList.append(["name": "send_message", "description": "Send a chat message", "inputSchema": ["type": "object"]])
        
        let getMessagesHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] _ in
            let messages = await MainActor.run { [weak self] () -> [String] in
                guard let chatVM = self?.chatViewModel else { return [] }
                return chatVM.messages.map { msg in
                    let role: String = switch msg.role {
                    case .user: "user"
                    case .assistant: "assistant"
                    case .system: "system"
                    }
                    return "\(role): \(msg.content)"
                }
            }
            if messages.isEmpty { return "No messages yet." }
            return messages.joined(separator: "\n")
        }
        
        server.register(
            name: "get_messages",
            description: "Get all chat messages.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: getMessagesHandler
        )
        bridgeHandlers["get_messages"] = getMessagesHandler
        bridgeToolList.append(["name": "get_messages", "description": "Get all chat messages", "inputSchema": ["type": "object"]])
        
        let getStatusHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] _ in
            guard let self else { return "Error: setup deallocated" }
            let status = await MainActor.run { [weak self] () -> String in
                guard let self else { return "Error: setup deallocated" }
                let connected = self.coordinator?.isConnected ?? false
                let agentRunning = self.coordinator?.isAgentRunning ?? false
                let waiting = self.chatViewModel?.isWaitingForAnswer ?? false
                let msgCount = self.chatViewModel?.messages.count ?? 0
                return """
                connected: \(connected)
                agentRunning: \(agentRunning)
                waitingForAnswer: \(waiting)
                messageCount: \(msgCount)
                mcpServerRunning: \(self.isRunning)
                bridgeState: \(self.bridgeState)
                """
            }
            return status
        }
        
        server.register(
            name: "get_status",
            description: "Get current app status.",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            handler: getStatusHandler
        )
        bridgeHandlers["get_status"] = getStatusHandler
        bridgeToolList.append(["name": "get_status", "description": "Get app status", "inputSchema": ["type": "object"]])
    }
    
    // MARK: - Reverse MCP Bridge
    
    /// Connect outward to a WebSocket bridge server.
    /// The bridge forwards MCP requests from curl to this app.
    func connectBridge(url: String) {
        bridgeTask?.cancel()
        bridgeState = "connecting"
        
        bridgeTask = Task { [weak self] in
            guard let self, let wsURL = URL(string: url) else {
                await MainActor.run { self?.bridgeState = "invalid URL" }
                return
            }
            
            while !Task.isCancelled {
                do {
                    let session = URLSession(configuration: .default)
                    let ws = session.webSocketTask(with: wsURL)
                    ws.resume()
                    
                    await MainActor.run { self.bridgeState = "connected" }
                    
                    // Process messages in a loop
                    while !Task.isCancelled {
                        let msg = try await ws.receive()
                        guard case .string(let text) = msg,
                              let data = text.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        
                        // Process MCP request using our handlers
                        let response = await self.handleMCPRequest(json)
                        
                        // Send response back
                        if let respData = try? JSONSerialization.data(withJSONObject: response),
                           let respStr = String(data: respData, encoding: .utf8) {
                            try await ws.send(.string(respStr))
                        }
                    }
                } catch {
                    await MainActor.run { self.bridgeState = "reconnecting..." }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            
            await MainActor.run { self.bridgeState = "off" }
        }
    }
    
    func disconnectBridge() {
        bridgeTask?.cancel()
        bridgeTask = nil
        bridgeState = "off"
    }
    
    /// Process an MCP JSON-RPC request using the same tool handlers.
    private func handleMCPRequest(_ json: [String: Any]) async -> [String: Any] {
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]
        let id = json["id"]
        
        switch method {
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "protocolVersion": "2025-03-26",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "neox-bridge", "version": "1.0.0"]
                ] as [String: Any]
            ]
        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": ["tools": bridgeToolList] as [String: Any]
            ]
        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return ["jsonrpc": "2.0", "id": id as Any, "error": ["code": -32602, "message": "Missing tool name"] as [String: Any]]
            }
            guard let handler = bridgeHandlers[toolName] else {
                return ["jsonrpc": "2.0", "id": id as Any, "error": ["code": -32602, "message": "Tool '\(toolName)' not found"] as [String: Any]]
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let jsonArgs = MCPServer.toJSONValue(arguments)
            
            do {
                let result = try await handler(jsonArgs)
                return [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "content": [["type": "text", "text": result]],
                        "isError": false
                    ] as [String: Any]
                ]
            } catch {
                return [
                    "jsonrpc": "2.0",
                    "id": id as Any,
                    "result": [
                        "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                        "isError": true
                    ] as [String: Any]
                ]
            }
        case "ping":
            return ["jsonrpc": "2.0", "id": id as Any, "result": [:] as [String: Any]]
        default:
            return ["jsonrpc": "2.0", "id": id as Any, "error": ["code": -32601, "message": "Method not found: \(method)"] as [String: Any]]
        }
    }
}
