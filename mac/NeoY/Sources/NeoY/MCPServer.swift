import Foundation
import Network
import Combine

/// MCP (Model Context Protocol) server using Streamable HTTP transport.
///
/// Runs a lightweight HTTP server via Network.framework that speaks
/// JSON-RPC 2.0 over POST — compatible with VS Code, Claude Desktop,
/// and any MCP client.
///
/// ```swift
/// let server = MCPServer(name: "my-app", port: 9223)
/// server.register(tools: myToolProvider.tools)
/// try server.start()
/// ```
///
/// VS Code `.vscode/mcp.json`:
/// ```json
/// { "servers": { "my-app": { "url": "http://localhost:9223/mcp" } } }
/// ```
public struct HTTPRouteResponse: Sendable {
    public let status: Int
    public let body: Data?
    public let contentType: String?

    public init(status: Int, body: Data? = nil, contentType: String? = nil) {
        self.status = status
        self.body = body
        self.contentType = contentType
    }
}

public typealias HTTPRouteHandler = @Sendable (
    String, [String: String], [String: String], Data?
) async -> HTTPRouteResponse

public typealias MCPResourceHandler = @Sendable (String) async throws -> String

@MainActor
public final class MCPServer {

    /// Server identity shown to MCP clients.
    public let name: String

    /// Server version shown to MCP clients.
    public let version: String

    /// TCP port the server listens on.
    public let port: UInt16

    /// Optional Bonjour service name; when set the listener advertises `_mcp._tcp`.
    public let bonjourName: String?

    private var listener: NWListener?
    private var toolHandlers: [String: ToolHandler] = [:]
    private var federatedToolProviders: [String: String] = [:]
    private var mcpTools: [[String: Any]] = []
    private var protectedToolNames: Set<String> = []
    private var mcpResources: [[String: Any]] = []
    private var resourceHandlers: [String: MCPResourceHandler] = [:]
    private var privilegedAccessToken: String?
    private var oauthService: NeoYOAuthService?
    private var remoteAllowedTools: Set<String> = []
    private var remoteAllowedProviders: Set<String> = []
    private var remoteAllowedResourceURIs: Set<String> = []
    private var httpRoutes: [String: HTTPRouteHandler] = [:]
    // Dedicated queue for all network I/O — avoids blocking on MainActor
    private let httpQueue = DispatchQueue(label: "mcp-server-http", qos: .userInitiated)
    // Snapshot of state for nonisolated access from httpQueue
    // Written on MainActor during register/start, read on httpQueue — safe by construction
    nonisolated(unsafe) private var _snapshotName: String = ""
    nonisolated(unsafe) private var _snapshotVersion: String = ""
    nonisolated(unsafe) private var _snapshotTools: [[String: Any]] = []
    nonisolated(unsafe) private var _snapshotHandlers: [String: ToolHandler] = [:]
    nonisolated(unsafe) private var _snapshotFederatedToolProviders: [String: String] = [:]
    nonisolated(unsafe) private var _snapshotToolNames: [String] = []
    nonisolated(unsafe) private var _snapshotProtectedToolNames: Set<String> = []
    nonisolated(unsafe) private var _snapshotResources: [[String: Any]] = []
    nonisolated(unsafe) private var _snapshotResourceHandlers: [String: MCPResourceHandler] = [:]
    nonisolated(unsafe) private var _snapshotPrivilegedAccessToken: String?
    nonisolated(unsafe) private var _snapshotOAuthService: NeoYOAuthService?
    nonisolated(unsafe) private var _snapshotRemoteAllowedTools: Set<String> = []
    nonisolated(unsafe) private var _snapshotRemoteAllowedProviders: Set<String> = []
    nonisolated(unsafe) private var _snapshotRemoteAllowedResourceURIs: Set<String> = []
    nonisolated(unsafe) private var _snapshotHTTPRoutes: [String: HTTPRouteHandler] = [:]

    /// Whether the server is currently listening.
    @Published public private(set) var isRunning = false

    /// Log callback for debugging.
    public var onLog: ((String) -> Void)?

    /// Called for every HTTP request line (e.g. "POST /mcp") — safe to call from the network queue.
    public nonisolated(unsafe) var onRequest: ((String) -> Void)?

    /// Called on every tools/call with the tool name and compact JSON of its arguments.
    public nonisolated(unsafe) var onToolCall: ((UUID, String, String) -> Void)?

    /// Called after a tool handler has returned or failed.
    public nonisolated(unsafe) var onToolCallFinished: ((UUID) -> Void)?

    public init(name: String = "mcp-server", version: String = "1.0.0", port: UInt16 = 9223, bonjourName: String? = nil) {
        self.name = name
        self.version = version
        self.port = port
        self.bonjourName = bonjourName
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Tool Registration

    /// Register tools from CopilotSDK `ToolDefinition` array.
    public func register(tools: [ToolDefinition], protected: Bool = false) {
        for tool in tools {
            toolHandlers[tool.name] = tool.handler
            mcpTools.append(buildMCPSchema(tool))
            if protected { protectedToolNames.insert(tool.name) }
        }
        refreshSnapshots()
    }

    /// Register a single tool by name, description, schema, and handler.
    public func register(name: String, description: String,
                         inputSchema: [String: Any] = ["type": "object", "properties": [String: Any]()],
                         protected: Bool = false,
                         handler: @escaping ToolHandler) {
        toolHandlers[name] = handler
        mcpTools.append([
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ])
        if protected { protectedToolNames.insert(name) }
        refreshSnapshots()
    }

    /// Register a federated MCP tool while preserving its full descriptor metadata.
    public func registerFederatedTool(descriptor: JSONValue, name: String, protected: Bool = true,
                                      provider: String? = nil, handler: @escaping ToolHandler) {
        guard case .object(var object) = descriptor else { return }
        object["name"] = .string(name)
        toolHandlers[name] = handler
        federatedToolProviders[name] = provider
        mcpTools.removeAll { ($0["name"] as? String) == name }
        mcpTools.append(object.mapValues(Self.jsonValueToAny))
        if protected { protectedToolNames.insert(name) }
        refreshSnapshots()
    }

    /// Register one MCP resource descriptor and its resources/read handler.
    public func registerFederatedResource(descriptor: JSONValue, uri: String, handler: @escaping MCPResourceHandler) {
        guard case .object(var object) = descriptor else { return }
        object["uri"] = .string(uri)
        resourceHandlers[uri] = handler
        mcpResources.removeAll { ($0["uri"] as? String) == uri }
        mcpResources.append(object.mapValues(Self.jsonValueToAny))
        refreshSnapshots()
    }

    public func unregisterResource(uri: String) {
        resourceHandlers.removeValue(forKey: uri)
        mcpResources.removeAll { ($0["uri"] as? String) == uri }
        refreshSnapshots()
    }

    /// Register an HTTP route on this server. Routes share the same listener/port as MCP.
    public func registerHTTPRoute(method: String, path: String, handler: @escaping HTTPRouteHandler) {
        httpRoutes["\(method.uppercased()) \(path)"] = handler
        refreshSnapshots()
    }

    /// Remove an HTTP route.
    public func unregisterHTTPRoute(method: String, path: String) {
        httpRoutes.removeValue(forKey: "\(method.uppercased()) \(path)")
        refreshSnapshots()
    }

    /// Unregister a tool by name.
    public func unregister(name: String) {
        toolHandlers.removeValue(forKey: name)
        federatedToolProviders.removeValue(forKey: name)
        mcpTools.removeAll { ($0["name"] as? String) == name }
        protectedToolNames.remove(name)
        refreshSnapshots()
    }

    public func setPrivilegedAccessToken(_ token: String?) {
        privilegedAccessToken = token
        refreshSnapshots()
    }

    public func configureOAuth(clientID: String, consentToken: String, stateURL: URL) {
        oauthService = NeoYOAuthService(clientID: clientID, consentToken: consentToken, stateURL: stateURL)
        refreshSnapshots()
    }

    func setRemoteAllowedTools(_ tools: Set<String>) {
        remoteAllowedTools = tools
        refreshSnapshots()
    }

    func setRemoteAllowedProviders(_ providers: Set<String>) {
        remoteAllowedProviders = providers
        refreshSnapshots()
    }

    func setRemoteAllowedResourceURIs(_ uris: Set<String>) {
        remoteAllowedResourceURIs = uris
        refreshSnapshots()
    }

    private func refreshSnapshots() {
        _snapshotName = name
        _snapshotVersion = version
        _snapshotTools = mcpTools
        _snapshotHandlers = toolHandlers
        _snapshotFederatedToolProviders = federatedToolProviders
        _snapshotToolNames = toolNames
        _snapshotProtectedToolNames = protectedToolNames
        _snapshotResources = mcpResources
        _snapshotResourceHandlers = resourceHandlers
        _snapshotPrivilegedAccessToken = privilegedAccessToken
        _snapshotOAuthService = oauthService
        _snapshotRemoteAllowedTools = remoteAllowedTools
        _snapshotRemoteAllowedProviders = remoteAllowedProviders
        _snapshotRemoteAllowedResourceURIs = remoteAllowedResourceURIs
        _snapshotHTTPRoutes = httpRoutes
    }

    /// All registered tool names.
    public var toolNames: [String] {
        Array(toolHandlers.keys).sorted()
    }

    /// Tool descriptors for in-process federation tests and diagnostics.
    /// External MCP clients use tools/list instead.
    var toolDescriptorsJSON: String {
        guard JSONSerialization.isValidJSONObject(mcpTools),
              let data = try? JSONSerialization.data(withJSONObject: mcpTools),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }

    @MainActor
    func invokeRegisteredTool(_ name: String, arguments: JSONValue) async throws -> String {
        guard let handler = toolHandlers[name] else {
            throw NeoYRuntimeControlError.federation("Unknown registered tool '\(name)'")
        }
        return try await handler(arguments)
    }

    public var resourceURIs: [String] {
        Array(resourceHandlers.keys).sorted()
    }

    /// Optional root directory for serving static files at `/assets/`.
    nonisolated(unsafe) private var _staticFileRoot: URL?

    /// Set a root directory to serve static files from via GET `/assets/...`.
    public func setStaticFileRoot(_ url: URL?) {
        _staticFileRoot = url
    }

    // MARK: - Server Lifecycle

    /// Start listening for MCP connections.
    public func start() throws {
        // Snapshot MainActor-isolated state for use on httpQueue
        _snapshotName = name
        _snapshotVersion = version
        _snapshotTools = mcpTools
        _snapshotHandlers = toolHandlers
        _snapshotFederatedToolProviders = federatedToolProviders
        _snapshotToolNames = toolNames
        _snapshotProtectedToolNames = protectedToolNames
        _snapshotResources = mcpResources
        _snapshotResourceHandlers = resourceHandlers
        _snapshotPrivilegedAccessToken = privilegedAccessToken
        _snapshotOAuthService = oauthService
        _snapshotRemoteAllowedTools = remoteAllowedTools
        _snapshotRemoteAllowedProviders = remoteAllowedProviders
        _snapshotRemoteAllowedResourceURIs = remoteAllowedResourceURIs
        _snapshotHTTPRoutes = httpRoutes

        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))

        if let bonjourName {
            listener.service = NWListener.Service(name: bonjourName, type: "_mcp._tcp")
        }

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    
                case .failed(let error):
                    self.isRunning = false
                    self.log("MCP Server failed: \(error)")
                case .cancelled:
                    self.isRunning = false
                    self.log("MCP Server stopped")
                default:
                    break
                }
            }
        }

        let queue = httpQueue
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.setupConnection(connection, queue: queue)
        }

        listener.start(queue: httpQueue)
        self.listener = listener
    }

    /// Stop the server.
    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    nonisolated static func remoteProvider(forToolName name: String,
                                           ownership: [String: String]) -> String? {
        if let owner = ownership[name] { return owner }
        if name.hasPrefix("mcp.") {
            let parts = name.split(separator: ".", maxSplits: 2).map(String.init)
            return parts.count >= 2 ? parts[1] : nil
        }
        if name.hasPrefix("events.") { return "events" }
        return nil
    }

    nonisolated private static func remoteProvider(forResourceURI uri: String) -> String? {
        for prefix in ["ui://", "mcp-federation://"] where uri.hasPrefix(prefix) {
            let rest = uri.dropFirst(prefix.count)
            return rest.split(separator: "/", maxSplits: 1).first.map(String.init)
        }
        return nil
    }

    nonisolated static func remoteResourceAllowed(uri: String,
                                                  explicitURIs: Set<String>,
                                                  providers: Set<String>) -> Bool {
        if explicitURIs.contains(uri) { return true }
        return remoteProvider(forResourceURI: uri).map { providers.contains($0) } ?? false
    }

    // MARK: - HTTP Connection Handling (runs on httpQueue, NOT MainActor)

    /// Set up a new connection — called from httpQueue via newConnectionHandler.
    nonisolated private func setupConnection(_ connection: NWConnection, queue: DispatchQueue) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveHTTPData(connection: connection, accumulated: Data())
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        // Auto-cancel after 900s to prevent CLOSE_WAIT buildup.
        // Generous so a large file transfer over slow WiFi isn't cut mid-stream.
        // Every response path cancels its connection after sending, so this only
        // sweeps connections that never complete a request.
        queue.asyncAfter(deadline: .now() + 900) { [weak connection] in
            connection?.cancel()
        }
        connection.start(queue: queue)
    }

    /// Accumulate TCP data until full HTTP request is received, then process it.
    nonisolated private func receiveHTTPData(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            var data = accumulated
            if let content, !content.isEmpty {
                data.append(content)
            }

            // Check if we have a complete HTTP request
            if let raw = String(data: data, encoding: .utf8),
               let headerEnd = raw.range(of: "\r\n\r\n") {
                let headers = String(raw[raw.startIndex..<headerEnd.lowerBound])
                var expectedContentLength = 0
                for line in headers.split(separator: "\r\n") {
                    if line.lowercased().hasPrefix("content-length:") {
                        let valStr = line.split(separator: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                        expectedContentLength = Int(valStr) ?? 0
                        break
                    }
                }

                let headerEndOffset = raw.distance(from: raw.startIndex, to: headerEnd.upperBound)
                let bodyLength = data.count - headerEndOffset

                if expectedContentLength == 0 || bodyLength >= expectedContentLength {
                    self.processHTTPRequest(raw: String(data: data, encoding: .utf8) ?? raw, connection: connection)
                    return
                }
            }

            if isComplete || (content == nil && accumulated.isEmpty) {
                if data.isEmpty {
                    connection.cancel()
                } else if let raw = String(data: data, encoding: .utf8) {
                    self.processHTTPRequest(raw: raw, connection: connection)
                } else {
                    connection.cancel()
                }
                return
            }

            self.receiveHTTPData(connection: connection, accumulated: data)
        }
    }

    // MARK: - HTTP Request Router (nonisolated — runs on httpQueue)

    nonisolated private func processHTTPRequest(raw: String, connection: NWConnection) {
        let lines = raw.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            sendHTTP(connection: connection, status: 400, body: nil)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTP(connection: connection, status: 400, body: nil)
            return
        }

        let method = String(parts[0])
        let requestTarget = String(parts[1])
        let path = String(requestTarget.split(separator: "?", maxSplits: 1).first ?? "")

        var rangeHeader: String?
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
            if key == "range" { rangeHeader = value }
        }
        let queryToken = URLComponents(string: "http://localhost\(requestTarget)")?
            .queryItems?.first(where: { $0.name == "token" })?.value
        let bearerToken: String? = {
            guard let value = headers["authorization"] else { return nil }
            let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
            return parts[1]
        }()
        let presentedToken = bearerToken ?? queryToken
        let isCloudflareProxy = headers["cf-connecting-ip"] != nil || headers["cf-ray"] != nil
        let isDirectLoopback = Self.isLoopback(connection.endpoint) && !isCloudflareProxy
        let isPrivileged = isDirectLoopback ||
            (_snapshotPrivilegedAccessToken != nil && presentedToken == _snapshotPrivilegedAccessToken) ||
            (_snapshotOAuthService?.isAuthorizedBearer(presentedToken) == true)

        if let onRequest { onRequest("\(method) \(path)") }

        // Extract body
        var body: Data?
        if let bodyStart = raw.range(of: "\r\n\r\n") {
            let bodyStr = String(raw[bodyStart.upperBound...])
            if !bodyStr.isEmpty {
                body = bodyStr.data(using: .utf8)
            }
        }

        if let oauth = _snapshotOAuthService,
           let response = oauth.handle(method: method, path: path, requestTarget: requestTarget, headers: headers, body: body) {
            sendHTTP(connection: connection, status: response.status, body: response.body,
                     contentType: response.contentType, extraHeaders: response.headers)
            return
        }

        if !isDirectLoopback, path == "/mcp", !isPrivileged, let oauth = _snapshotOAuthService {
            let scheme = headers["x-forwarded-proto"]?.lowercased() == "https" || isCloudflareProxy ? "https" : "http"
            if let host = headers["host"] {
                sendHTTP(connection: connection, status: 401, body: nil,
                         extraHeaders: oauth.challengeHeaders(origin: "\(scheme)://\(host)"))
                return
            }
        }

        if let route = _snapshotHTTPRoutes["\(method) \(path)"] {
            let query = URLComponents(string: "http://localhost\(requestTarget)")?.queryItems ?? []
            var queryValues: [String: String] = [:]
            for item in query {
                if let value = item.value { queryValues[item.name] = value }
            }
            Task {
                let response = await route(method, headers, queryValues, body)
                sendHTTP(connection: connection, status: response.status, body: response.body,
                          contentType: response.contentType ?? "application/json")
            }
            return
        }

        // CORS preflight (kept for completeness — MCP clients are not browsers)
        if method == "OPTIONS" {
            sendHTTP(connection: connection, status: 204, body: nil)
            return
        }

        switch (method, path) {
        case ("POST", "/mcp"):
            handleMCPPostNonisolated(
                body: body,
                connection: connection,
                isLocal: isDirectLoopback,
                authorized: isPrivileged
            )

        case ("GET", "/mcp"):
            sendHTTP(connection: connection, status: 405, body: nil)

        case ("DELETE", "/mcp"):
            sendHTTP(connection: connection, status: 200, body: nil)

        case ("GET", "/"):
            let info: [String: Any] = [
                "name": _snapshotName,
                "mcp_endpoint": "/mcp",
                "protocol": "MCP (Streamable HTTP)"
            ]
            sendJSON(connection: connection, status: 200, json: info)

        default:
            // Static file serving: GET/HEAD /files/... (alias /public/... kept for compatibility)
            if ["GET", "HEAD"].contains(method),
               path.hasPrefix("/files/") || path.hasPrefix("/public/"),
               let root = _staticFileRoot {
                let prefix = path.hasPrefix("/files/") ? "/files/" : "/public/"
                let relativePath = String(path.dropFirst(prefix.count))
                serveStaticFile(
                    relativePath: relativePath,
                    root: root,
                    rangeHeader: rangeHeader,
                    headOnly: method == "HEAD",
                    connection: connection
                )
            } else {
                sendHTTP(connection: connection, status: 404, body: "Not found".data(using: .utf8))
            }
        }
    }

    nonisolated private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        let value = String(describing: endpoint).lowercased()
        return value.contains("127.0.0.1") || value.contains("::1") || value.contains("localhost")
    }

    // MARK: - MCP JSON-RPC Handler (nonisolated)

    nonisolated private func handleMCPPostNonisolated(
        body: Data?, connection: NWConnection, isLocal: Bool, authorized: Bool
    ) {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            sendJSONRPCError(connection: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"]
        let method = json["method"] as? String
        let params = json["params"] as? [String: Any] ?? [:]

        guard id != nil else {
            sendHTTP(connection: connection, status: 202, body: nil)
            return
        }

        guard let method else {
            sendJSONRPCError(connection: connection, id: id, code: -32600, message: "Missing method")
            return
        }

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2025-03-26",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["listChanged": false, "subscribe": false],
                ],
                "serverInfo": ["name": _snapshotName, "version": _snapshotVersion]
            ]
            sendJSONRPCResult(connection: connection, id: id, result: result)

        case "resources/list":
            let visibleResources: [[String: Any]]
            if isLocal {
                visibleResources = _snapshotResources
            } else if authorized {
                visibleResources = _snapshotResources.filter { resource in
                    guard let uri = resource["uri"] as? String else { return false }
                    return Self.remoteResourceAllowed(uri: uri,
                                                      explicitURIs: _snapshotRemoteAllowedResourceURIs,
                                                      providers: _snapshotRemoteAllowedProviders)
                }
            } else {
                visibleResources = []
            }
            sendJSONRPCResult(connection: connection, id: id, result: ["resources": visibleResources])

        case "resources/read":
            guard let uri = params["uri"] as? String, !uri.isEmpty else {
                sendJSONRPCError(connection: connection, id: id, code: -32602, message: "Missing resource uri")
                return
            }
            if !isLocal {
                guard authorized else {
                    sendJSONRPCError(connection: connection, id: id, code: -32001, message: "Remote MCP requires a valid NeoY token")
                    return
                }
                guard Self.remoteResourceAllowed(uri: uri,
                                                 explicitURIs: _snapshotRemoteAllowedResourceURIs,
                                                 providers: _snapshotRemoteAllowedProviders) else {
                    sendJSONRPCError(connection: connection, id: id, code: -32003, message: "MCP resource is not enabled for remote access")
                    return
                }
            }
            guard let handler = _snapshotResourceHandlers[uri] else {
                sendJSONRPCError(connection: connection, id: id, code: -32002, message: "Unknown resource: \(uri)")
                return
            }
            Task.detached { [weak self] in
                do {
                    let encoded = try await handler(uri)
                    guard encoded.hasPrefix("mcpresult:"),
                          let data = Data(base64Encoded: String(encoded.dropFirst("mcpresult:".count))),
                          let forwarded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw NeoYRuntimeControlError.federation("federated resource result is invalid")
                    }
                    self?.sendJSONRPCResult(connection: connection, id: id, result: forwarded)
                } catch {
                    self?.sendJSONRPCError(connection: connection, id: id, code: -32002, message: error.localizedDescription)
                }
            }

        case "tools/list":
            let visibleTools: [[String: Any]]
            if isLocal {
                visibleTools = _snapshotTools
            } else if authorized {
                visibleTools = _snapshotTools.filter {
                    guard let name = $0["name"] as? String else { return false }
                    return _snapshotRemoteAllowedTools.contains(name)
                        || Self.remoteProvider(forToolName: name, ownership: _snapshotFederatedToolProviders).map { _snapshotRemoteAllowedProviders.contains($0) } == true
                }
            } else {
                visibleTools = []
            }
            sendJSONRPCResult(connection: connection, id: id, result: ["tools": visibleTools])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                sendJSONRPCError(connection: connection, id: id, code: -32602, message: "Missing tool name")
                return
            }
            if !isLocal {
                guard authorized else {
                    sendJSONRPCError(connection: connection, id: id, code: -32001,
                        message: "Remote MCP requires a valid NeoY token")
                    return
                }
                let toolAllowed = _snapshotRemoteAllowedTools.contains(toolName)
                let providerAllowed = Self.remoteProvider(forToolName: toolName, ownership: _snapshotFederatedToolProviders).map { _snapshotRemoteAllowedProviders.contains($0) } ?? false
                guard toolAllowed || providerAllowed else {
                    sendJSONRPCError(connection: connection, id: id, code: -32003,
                        message: "Tool '\(toolName)' is not enabled for remote access")
                    return
                }
            }
            guard let handler = _snapshotHandlers[toolName] else {
                sendJSONRPCError(connection: connection, id: id, code: -32602,
                    message: "Tool '\(toolName)' not found. Available: \(_snapshotToolNames.joined(separator: ", "))")
                return
            }

            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let jsonArgs = Self.toJSONValue(arguments)
            let callID = UUID()
            if let onToolCall {
                let argsPreview: String
                if let data = try? JSONSerialization.data(withJSONObject: Self.jsonValueToAny(jsonArgs), options: [.sortedKeys]) {
                    argsPreview = String(data: data, encoding: .utf8) ?? ""
                } else { argsPreview = "" }
                onToolCall(callID, toolName, argsPreview)
            }

            // Tool handlers may need MainActor — run in a detached task
            Task.detached { [weak self] in
                defer { self?.onToolCallFinished?(callID) }
                do {
                    let result = try await handler(jsonArgs)
                    // Image results come back as "b64:<mime>,<base64>"; everything else is text.
                    // (Never infer from length/newlines — a long single-line JSON result is text.)
                    if result.hasPrefix("mcpresult:"),
                       let data = Data(base64Encoded: String(result.dropFirst("mcpresult:".count))),
                       let forwarded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self?.sendJSONRPCResult(connection: connection, id: id, result: forwarded)
                        return
                    }
                    let content: [[String: Any]]
                    if result.hasPrefix("b64:"), let comma = result.firstIndex(of: ",") {
                        let mime = String(result[result.index(result.startIndex, offsetBy: 4)..<comma])
                        let payload = String(result[result.index(after: comma)...])
                        content = [["type": "image", "data": payload, "mimeType": mime.isEmpty ? "image/png" : mime]]
                    } else {
                        content = [["type": "text", "text": result]]
                    }
                    self?.sendJSONRPCResult(connection: connection, id: id, result: [
                        "content": content, "isError": false
                    ])
                } catch {
                    self?.sendJSONRPCResult(connection: connection, id: id, result: [
                        "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                        "isError": true
                    ])
                }
            }

        case "ping":
            sendJSONRPCResult(connection: connection, id: id, result: [:] as [String: Any])

        default:
            sendJSONRPCError(connection: connection, id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - HTTP Response Helpers (nonisolated for httpQueue access)

    nonisolated private func sendJSONRPCResult(connection: NWConnection, id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    nonisolated private func sendJSONRPCError(connection: NWConnection, id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id { response["id"] = id }
        sendJSON(connection: connection, status: 200, json: response)
    }

    nonisolated private func sendJSON(connection: NWConnection, status: Int, json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            connection.cancel()
            return
        }
        sendHTTP(connection: connection, status: status, body: jsonData, contentType: "application/json")
    }

    nonisolated private func sendHTTP(connection: NWConnection, status: Int, body: Data?,
                          contentType: String = "application/json",
                          extraHeaders: [String: String] = [:]) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 204: statusText = "No Content"
        case 302: statusText = "Found"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 403: statusText = "Forbidden"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var headers = [
            "HTTP/1.1 \(status) \(statusText)",
            "Connection: close"
        ]

        if let body, !body.isEmpty {
            headers.append("Content-Type: \(contentType)")
            headers.append("Content-Length: \(body.count)")
        }

        for (key, value) in extraHeaders {
            headers.append("\(key): \(value)")
        }

        headers.append("")
        headers.append("")

        var responseData = Data(headers.joined(separator: "\r\n").utf8)
        if let body { responseData.append(body) }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - MCP Tool Schema Builder

    private func buildMCPSchema(_ tool: ToolDefinition) -> [String: Any] {
        var schema: [String: Any] = ["name": tool.name]
        if let desc = tool.description { schema["description"] = desc }

        if let params = tool.parameters, case .object = params {
            schema["inputSchema"] = jsonValueToAny(params)
        } else {
            schema["inputSchema"] = [
                "type": "object",
                "properties": [:] as [String: Any]
            ]
        }

        return schema
    }

    // MARK: - JSON Conversion

    /// Convert Foundation types to `JSONValue`.
    nonisolated public static func toJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let str as String:
            return .string(str)
        case let num as NSNumber:
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                return .bool(num.boolValue)
            }
            if num.doubleValue == Double(num.intValue) {
                return .int(num.intValue)
            }
            return .double(num.doubleValue)
        case let dict as [String: Any]:
            return .object(dict.mapValues { toJSONValue($0) })
        case let arr as [Any]:
            return .array(arr.map { toJSONValue($0) })
        case is NSNull:
            return .null
        default:
            return .string(String(describing: value))
        }
    }

    /// Convert `JSONValue` to Foundation types for JSON serialization.
    nonisolated public static func jsonValueToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .object(let dict): return dict.mapValues { jsonValueToAny($0) }
        case .array(let arr): return arr.map { jsonValueToAny($0) }
        }
    }

    // Private instance version for internal use
    private func jsonValueToAny(_ value: JSONValue) -> Any {
        Self.jsonValueToAny(value)
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    // MARK: - Static File Serving

    nonisolated private func serveStaticFile(
        relativePath: String,
        root: URL,
        rangeHeader: String?,
        headOnly: Bool,
        connection: NWConnection
    ) {
        // Security: prevent path traversal
        let fileURL = root.appendingPathComponent(relativePath)

        // Verify the resolved path is still under root
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        guard fileURL.standardizedFileURL.path.hasPrefix(rootPath) else {
            sendHTTP(connection: connection, status: 403, body: "Forbidden".data(using: .utf8))
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value, fileSize > 0 else {
            sendHTTP(connection: connection, status: 404, body: "Not found".data(using: .utf8))
            return
        }

        let mime = Self.mime(forExtension: fileURL.pathExtension.lowercased())

        // Parse Range: bytes=a-b | bytes=a- | bytes=-suffix
        var start: UInt64 = 0
        var end: UInt64 = fileSize - 1
        var isRange = false
        if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count)
            let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let head = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let tail = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if let s = UInt64(head) {
                start = min(s, fileSize - 1)
                if let e = UInt64(tail) { end = min(e, fileSize - 1) }
                isRange = true
            } else if head.isEmpty, let suffix = UInt64(tail) {
                start = fileSize > suffix ? fileSize - suffix : 0
                isRange = true
            }
        }
        if end < start { end = start }
        let contentLength = end - start + 1

        var headers: [String]
        if isRange {
            headers = [
                "HTTP/1.1 206 Partial Content",
                "Content-Type: \(mime)",
                "Content-Range: bytes \(start)-\(end)/\(fileSize)",
                "Content-Length: \(contentLength)",
                "Accept-Ranges: bytes",
                "Connection: close"
            ]
        } else {
            headers = [
                "HTTP/1.1 200 OK",
                "Content-Type: \(mime)",
                "Content-Length: \(contentLength)",
                "Accept-Ranges: bytes",
                "Connection: close"
            ]
        }

        let headerData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if headOnly {
            connection.send(content: headerData, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            sendHTTP(connection: connection, status: 500, body: "Read error".data(using: .utf8))
            return
        }
        if start > 0 { try? handle.seek(toOffset: start) }

        connection.send(content: headerData, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            Self.streamFileChunks(connection: connection, handle: handle, remaining: contentLength)
        })
    }

    /// Stream file contents in 1MB chunks — memory stays bounded for multi-GB videos.
    nonisolated private static func streamFileChunks(connection: NWConnection, handle: FileHandle, remaining: UInt64) {
        guard remaining > 0 else {
            try? handle.close()
            connection.cancel()
            return
        }
        let size = min(Int(remaining), 1 << 20)
        guard let chunk = try? handle.read(upToCount: size), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        let sent = UInt64(chunk.count)
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            streamFileChunks(connection: connection, handle: handle, remaining: remaining - sent)
        })
    }

    nonisolated private static func mime(forExtension ext: String) -> String {
        switch ext {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "json": return "application/json"
        case "srt": return "text/plain"
        case "html", "htm": return "text/html"
        case "js": return "application/javascript"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }
}
