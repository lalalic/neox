import SwiftUI
import AppAgent
import CopilotChat
import CopilotSDK
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
    weak var coordinator: AgentCoordinator?
    private var bridgeTask: Task<Void, Never>?
    
    private init() {}
    
    func start(port: UInt16 = 9223) throws {
        // Prevent double-start race: if we already have a server, don't recreate
        if server != nil { return }
        self.port = port
        self.serverState = "starting"
        let server = MCPServer(name: "neox", port: port)
        let provider = AppAgentToolProvider()
        self.toolProvider = provider

        // Single unified tool — UI automation only
        let unifiedHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { args in
            guard case .object(let dict) = args,
                  case .string(let command) = dict["command"] else {
                return "Error: 'command' parameter required"
            }
            return await MainActor.run {
                provider.dispatch(command: command, args: dict)
            }
        }
        server.register(
            name: "app_agent",
            description: AppAgentToolProvider.skillPrompt,
            inputSchema: [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "enum": ["snapshot", "tap", "tap_xy", "type", "screenshot",
                                 "swipe", "long_press", "find", "scroll_to", "pick"],
                        "description": "The sub-command to execute"
                    ] as [String: Any],
                    "ref": ["type": "string", "description": "Element ref from snapshot, e.g. 'r5'"],
                    "x": ["type": "number", "description": "X coordinate for tap_xy"],
                    "y": ["type": "number", "description": "Y coordinate for tap_xy"],
                    "text": ["type": "string", "description": "Text to type/search/send"],
                    "clear": ["type": "boolean", "description": "Clear before typing. Default true."],
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "duration": ["type": "number", "description": "Long-press seconds. Default 1.0."],
                    "component": ["type": "integer", "description": "Picker column index. Default 0."]
                ] as [String: Any],
                "required": ["command"]
            ] as [String: Any],
            handler: unifiedHandler
        )
        bridgeHandlers["app_agent"] = unifiedHandler
        bridgeToolList.append([
            "name": "app_agent",
            "description": "Unified iOS app control — UI automation + chat",
            "inputSchema": ["type": "object"]
        ])

        try server.start()
        self.server = server
        
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
