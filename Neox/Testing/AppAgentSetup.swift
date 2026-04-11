import SwiftUI
import AppAgent
import CopilotChat
import CopilotSDK
import WebKitAgent
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

        // WeChat test setup tool
        let wechatSetupHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] args in
            return await MainActor.run {
                guard let self else { return "Error: setup deallocated" }
                let roomName: String
                let directName: String
                if case .object(let dict) = args {
                    if case .string(let r) = dict["room"] { roomName = r } else { roomName = "3人组" }
                    if case .string(let d) = dict["direct"] { directName = d } else { directName = "文件传输助手" }
                } else {
                    roomName = "3人组"
                    directName = "文件传输助手"
                }
                return self.setupWeChatTest(roomName: roomName, directName: directName)
            }
        }
        server.register(
            name: "wechat_test_setup",
            description: "Set up WeChat test bindings for E2E testing. Finds contacts and creates project bindings.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "room": ["type": "string", "description": "Room name to bind (default: 3人组)"],
                    "direct": ["type": "string", "description": "1:1 contact name to bind (default: 文件传输助手)"],
                ] as [String: Any]
            ] as [String: Any],
            handler: wechatSetupHandler
        )
        bridgeHandlers["wechat_test_setup"] = wechatSetupHandler
        bridgeToolList.append([
            "name": "wechat_test_setup",
            "description": "Set up WeChat test bindings",
            "inputSchema": ["type": "object"]
        ])

        // WeChat send message tool
        let wechatSendHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] args in
            return await MainActor.run {
                guard let self, let coordinator = self.coordinator else { return "Error: not ready" }
                let service = coordinator.weChatService
                guard service.isOnline else { return "Error: WeChat not online" }

                guard case .object(let dict) = args,
                      case .string(let to) = dict["to"],
                      case .string(let message) = dict["message"] else {
                    return "Error: 'to' and 'message' are required"
                }

                // Resolve contact name → userName
                let contacts = service.contacts
                let contact = contacts.first(where: { $0.name == to || $0.userName == to || $0.remarkName == to })
                let targetId = contact?.userName ?? to

                Task {
                    await service.sendToContact(targetId, message: message, watermark: false)
                }
                return "Sent to \(contact?.name ?? to) (id: \(targetId))"
            }
        }
        server.register(
            name: "wechat_send",
            description: "Send a WeChat message to a contact or room.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Contact name, remark name, or UserName to send to"],
                    "message": ["type": "string", "description": "Message text to send"],
                ] as [String: Any],
                "required": ["to", "message"]
            ] as [String: Any],
            handler: wechatSendHandler
        )
        bridgeHandlers["wechat_send"] = wechatSendHandler
        bridgeToolList.append([
            "name": "wechat_send",
            "description": "Send a WeChat message",
            "inputSchema": ["type": "object"]
        ])

        // WeChat webkit send (untracked — simulates incoming message for E2E test)
        let wechatWebkitHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] args in
            // Extract parameters and resolve contact on MainActor
            let (targetId, contactName, channel): (String, String, WeChatBridge) = try await MainActor.run {
                guard let self, let coordinator = self.coordinator else { throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "not ready"]) }
                let service = coordinator.weChatService
                guard service.isOnline else { throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "WeChat not online"]) }

                guard case .object(let dict) = args,
                      case .string(let to) = dict["to"],
                      case .string(let message) = dict["message"] else {
                    throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "'to' and 'message' are required"])
                }
                _ = message // used below

                let contacts = service.contacts
                let contact = contacts.first(where: { $0.name == to || $0.userName == to || $0.remarkName == to })
                let tid = contact?.userName ?? to
                guard let ch = service.channel else { throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "WeChat channel not available"]) }
                return (tid, contact?.name ?? to, ch)
            }
            // Extract message from args again (can't capture from MainActor block easily)
            guard case .object(let dict) = args, case .string(let message) = dict["message"] else {
                return "Error: 'message' required"
            }
            // Send untracked (async, calls evaluateJavaScript on MainActor internally)
            let result = await channel.sendUntracked(to: targetId, content: message)
            if result.ok {
                return "Sent (untracked) to \(contactName) — bridge will treat as incoming. msgId: \(result.msgId ?? "unknown")"
            } else {
                return "Error: send failed"
            }
        }
        server.register(
            name: "wechat_webkit_send",
            description: "Send a WeChat message bypassing sent-by-us tracking. The bridge will treat this as an incoming message, triggering the routing pipeline. For E2E testing.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "to": ["type": "string", "description": "Contact name, remark name, or UserName to send to"],
                    "message": ["type": "string", "description": "Message text to send"],
                ] as [String: Any],
                "required": ["to", "message"]
            ] as [String: Any],
            handler: wechatWebkitHandler
        )
        bridgeHandlers["wechat_webkit_send"] = wechatWebkitHandler
        bridgeToolList.append([
            "name": "wechat_webkit_send",
            "description": "Send WeChat message (untracked — simulates incoming)",
            "inputSchema": ["type": "object"]
        ])

        // Simulate incoming WeChat message (inject directly into router)
        let wechatSimHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] args in
            return await MainActor.run {
                guard let self, let coordinator = self.coordinator else { return "Error: not ready" }
                let service = coordinator.weChatService

                guard case .object(let dict) = args,
                      case .string(let from) = dict["from"],
                      case .string(let message) = dict["message"] else {
                    return "Error: 'from' and 'message' are required"
                }

                // Resolve contact name → userName
                let contacts = service.contacts
                let contact = contacts.first(where: { $0.name == from || $0.userName == from || $0.remarkName == from })
                let fromId = contact?.userName ?? from
                let isRoom = fromId.hasPrefix("@@")

                // Build content: for rooms, prefix with a fake sender
                let content: String
                if isRoom {
                    if case .string(let sender) = dict["sender"] {
                        // Resolve sender name to userName
                        let senderContact = contacts.first(where: { $0.name == sender || $0.userName == sender })
                        let senderUserName = senderContact?.userName ?? sender
                        content = "\(senderUserName):\n\(message)"
                    } else {
                        content = "fake-sender:\n\(message)"
                    }
                } else {
                    content = message
                }

                let msgType: Int
                if case .int(let t) = dict["msgType"] { msgType = t }
                else if case .double(let t) = dict["msgType"] { msgType = Int(t) }
                else { msgType = 1 }

                let fakeMsg = WeChatMessage(
                    msgId: "sim-\(Int(Date().timeIntervalSince1970 * 1000))",
                    msgType: msgType,
                    content: content,
                    fromUserName: fromId,
                    toUserName: "self",
                    fromContact: contact,
                    isRoom: isRoom
                )

                // Route directly through the message router
                coordinator.messageRouter?.route(fakeMsg)
                return "Simulated incoming message from \(contact?.name ?? from) (id: \(fromId), room: \(isRoom), type: \(msgType)): \(message)"
            }
        }
        server.register(
            name: "wechat_simulate_incoming",
            description: "Simulate a WeChat incoming message for E2E testing. Injects a fake message directly into the routing pipeline. Works without WeChat login.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "Contact/room name or UserName the message is 'from'"],
                    "message": ["type": "string", "description": "Message text"],
                    "sender": ["type": "string", "description": "(Rooms only) Name of the sender within the room"],
                    "msgType": ["type": "number", "description": "Message type: 1=text, 34=voice, 3=image, 49=app (default: 1)"],
                ] as [String: Any],
                "required": ["from", "message"]
            ] as [String: Any],
            handler: wechatSimHandler
        )
        bridgeHandlers["wechat_simulate_incoming"] = wechatSimHandler
        bridgeToolList.append([
            "name": "wechat_simulate_incoming",
            "description": "Simulate incoming WeChat message for E2E testing",
            "inputSchema": ["type": "object"]
        ])

        // ── wechat_router_status: diagnostic tool ──
        let routerStatusHandler: @Sendable (AppAgent.JSONValue) async throws -> String = { [weak self] _ in
            return await MainActor.run {
                guard let self, let coordinator = self.coordinator else { return "Error: coordinator gone" }
                var lines: [String] = []
                let router = coordinator.messageRouter
                lines.append("Response log:")
                if let log = router?.responseLog, !log.isEmpty {
                    for entry in log { lines.append("  \(entry)") }
                } else {
                    lines.append("  (empty)")
                }
                lines.append("Project sessions: \(coordinator.projectSessions.count)")
                for (pid, vm) in coordinator.projectSessions {
                    let ptype = coordinator.readProjectType(projectId: pid) ?? "nil"
                    lines.append("  \(pid): state=\(vm.chatState) type=\(ptype)")
                }
                // Show pending guardrail approvals
                if let approvals = router?.guardrails?.pendingApprovals, !approvals.isEmpty {
                    lines.append("Pending approvals: \(approvals.count)")
                    for a in approvals {
                        lines.append("  [\(a.id.prefix(8))] project=\(a.projectId) reason=\(a.reason)")
                    }
                }
                // Debug: last incoming text per project
                if let lastTexts = router?.lastIncomingText, !lastTexts.isEmpty {
                    lines.append("Last incoming:")
                    for (pid, text) in lastTexts {
                        lines.append("  \(pid): \(String(text.prefix(60)))")
                    }
                }
                return lines.joined(separator: "\n")
            }
        }
        server.register(
            name: "wechat_router_status",
            description: "Show router response log and project session states",
            inputSchema: ["type": "object"] as [String: Any],
            handler: routerStatusHandler
        )
        bridgeHandlers["wechat_router_status"] = routerStatusHandler
        bridgeToolList.append([
            "name": "wechat_router_status",
            "description": "Show router response log and project session states",
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

    // MARK: - WeChat Test Setup

    /// Set up test bindings for WeChat bidirectional E2E testing.
    /// Finds target contacts in the WeChat bridge and creates project bindings.
    /// - Parameters:
    ///   - roomName: Name of the room to bind (e.g. "3人组")
    ///   - directName: Name of the 1:1 contact to bind (e.g. "文件传输助手")
    /// - Returns: Status message with created bindings and contact IDs.
    func setupWeChatTest(roomName: String = "3人组", directName: String = "文件传输助手") -> String {
        guard let coordinator else { return "Error: coordinator not set" }
        let service = coordinator.weChatService
        guard service.isOnline else { return "Error: WeChat not online" }

        let contacts = service.contacts
        if contacts.isEmpty { return "Error: no contacts loaded" }

        var results: [String] = []
        results.append("Available contacts: \(contacts.count)")

        // Find room contact
        let room = contacts.first(where: { $0.name == roomName || $0.userName.hasPrefix("@@") && $0.name.contains(roomName) })
        // Find 1:1 contact
        let direct = contacts.first(where: { $0.name == directName })

        // Create project-assistant binding for the room
        if let room {
            let binding = WeChatContactBindings(
                contacts: [WeChatContactBindings.BoundContact(
                    id: room.userName,
                    name: room.name,
                    isRoom: true,
                    weight: nil,
                    autoReply: nil,
                    members: nil  // No member weights for now — all messages pass through
                )],
                routingActive: true
            )
            service.setBindings(binding, for: "test-room-assistant")
            ensurePackageJSON(projectId: "test-room-assistant", projectType: "project-assistant", workspaceURL: service.workspaceURL)
            coordinator.destroyProjectSession(projectId: "test-room-assistant")
            results.append("✅ Room '\(room.name)' (id: \(room.userName)) → project 'test-room-assistant'")
        } else {
            results.append("⚠️ Room '\(roomName)' not found")
            // List available rooms
            let rooms = contacts.filter { $0.userName.hasPrefix("@@") }
            results.append("Available rooms: \(rooms.map { "\($0.name) (\($0.userName.prefix(12))...)" }.joined(separator: ", "))")
        }

        // Create wechat-assistant binding for the direct contact
        if let direct {
            let binding = WeChatContactBindings(
                contacts: [WeChatContactBindings.BoundContact(
                    id: direct.userName,
                    name: direct.name,
                    isRoom: false,
                    weight: 50,
                    autoReply: true,
                    members: nil
                )],
                routingActive: true
            )
            service.setBindings(binding, for: "test-direct-assistant")
            ensurePackageJSON(projectId: "test-direct-assistant", projectType: "wechat-assistant", workspaceURL: service.workspaceURL)
            coordinator.destroyProjectSession(projectId: "test-direct-assistant")
            results.append("✅ Contact '\(direct.name)' (id: \(direct.userName)) → project 'test-direct-assistant'")
        } else {
            results.append("⚠️ Contact '\(directName)' not found")
            // List some contacts
            let people = contacts.filter { !$0.userName.hasPrefix("@@") }.prefix(10)
            results.append("Available contacts (first 10): \(people.map { $0.name }.joined(separator: ", "))")
        }

        return results.joined(separator: "\n")
    }

    /// Ensure a project directory has a package.json with the correct projectType.
    private func ensurePackageJSON(projectId: String, projectType: String, workspaceURL: URL) {
        let projectDir = workspaceURL.appendingPathComponent(projectId, isDirectory: true)
        let packageURL = projectDir.appendingPathComponent("package.json")
        let manager = FileManager.default
        // Skip if package.json already exists with correct type
        if let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["projectType"] as? String == projectType {
            return
        }
        // Create directory if needed
        try? manager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let content: [String: Any] = [
            "name": projectId,
            "version": "0.1.0",
            "projectType": projectType
        ]
        if let data = try? JSONSerialization.data(withJSONObject: content, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: packageURL)
            NSLog("[WeChatTest] Created package.json for %@ (type: %@)", projectId, projectType)
        }
    }
}
