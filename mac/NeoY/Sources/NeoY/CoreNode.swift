import Foundation
import Network

struct NeoYNodeConfiguration: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let token: String
    var isEnabled: Bool = true
}

actor NeoYNodeStore {
    private let file = NeoYPaths.supportDirectory.appendingPathComponent("trusted-nodes.json")
    private var nodes: [NeoYNodeConfiguration] = []

    init() {
        if let data = try? Data(contentsOf: file),
           let values = try? JSONDecoder().decode([NeoYNodeConfiguration].self, from: data) {
            nodes = values
        }
    }

    func list() -> [NeoYNodeConfiguration] {
        nodes.sorted { $0.name < $1.name }
    }

    func get(_ name: String) -> NeoYNodeConfiguration? {
        nodes.first { $0.name == name }
    }

    func upsert(_ node: NeoYNodeConfiguration) throws {
        nodes.removeAll { $0.name == node.name }
        nodes.append(node)
        try persist()
    }

    func remove(_ name: String) throws {
        guard nodes.contains(where: { $0.name == name }) else {
            throw NeoYCoreError.notFound("node '\(name)' not found")
        }
        nodes.removeAll { $0.name == name }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: NeoYPaths.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(nodes).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

actor NeoYNodeService {
    private let store: NeoYNodeStore
    private static var allowedRemoteCoreTools: Set<String> { NeoYCoreRuntime.toolNames }

    init(store: NeoYNodeStore = NeoYNodeStore()) {
        self.store = store
    }

    func execute(_ raw: String) async throws -> String {
        let parsed = try NeoYCommandLine.parse(raw)
        guard let verb = parsed.tokens.first else { return Self.help }
        switch verb {
        case "help": return Self.help
        case "local":
            return localIdentity()
        case "token":
            return localToken()
        case "discover":
            return try await discover(parsed.tokens)
        case "list":
            return NeoYCoreJSON.encode(await store.list().map { PublicNode($0) })
        case "pair":
            return try await pair(parsed.tokens)
        case "remove":
            guard parsed.tokens.count == 2 else { throw NeoYCoreError.invalidCommand("usage: remove <name>") }
            try await store.remove(parsed.tokens[1])
            return "{\"ok\":true,\"name\":\"\(escape(parsed.tokens[1]))\"}"
        case "status":
            guard parsed.tokens.count == 2, let node = await store.get(parsed.tokens[1]) else {
                throw NeoYCoreError.notFound("usage: status <trusted-node>")
            }
            return try await status(node)
        case "invoke":
            return try await invoke(parsed)
        default:
            throw NeoYCoreError.invalidCommand("unknown node command '\(verb)'; run 'help'")
        }
    }

    private struct PublicNode: Codable {
        let name: String
        let url: String
        let enabled: Bool

        init(_ node: NeoYNodeConfiguration) {
            name = node.name
            url = node.url
            enabled = node.isEnabled
        }
    }

    private struct DiscoveredNode: Codable, Sendable {
        let name: String
        let endpoint: String
    }

    private final class DiscoveryAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: DiscoveredNode] = [:]

        func update(_ results: Set<NWBrowser.Result>) {
            lock.lock()
            defer { lock.unlock() }
            for result in results {
                let endpoint = String(describing: result.endpoint)
                let name: String
                switch result.endpoint {
                case .service(let serviceName, _, _, _): name = serviceName
                default: name = endpoint
                }
                values[endpoint] = DiscoveredNode(name: name, endpoint: endpoint)
            }
        }

        func snapshot() -> [DiscoveredNode] {
            lock.lock()
            defer { lock.unlock() }
            return values.values.sorted { $0.name < $1.name }
        }
    }

    private func discover(_ tokens: [String]) async throws -> String {
        var seconds = 2.0
        if tokens.count == 3, tokens[1] == "--seconds", let value = Double(tokens[2]) {
            seconds = min(max(value, 0.25), 10)
        } else if tokens.count != 1 {
            throw NeoYCoreError.invalidCommand("usage: discover [--seconds 0.25...10]")
        }

        let accumulator = DiscoveryAccumulator()
        let browser = NWBrowser(for: .bonjour(type: "_mcp._tcp", domain: "local."), using: .tcp)
        let queue = DispatchQueue(label: "neoy.node.discovery")
        browser.browseResultsChangedHandler = { results, _ in
            accumulator.update(results)
        }
        browser.start(queue: queue)
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()
        return NeoYCoreJSON.encode(accumulator.snapshot())
    }

    private func pair(_ tokens: [String]) async throws -> String {
        guard tokens.count == 4 else {
            throw NeoYCoreError.invalidCommand("usage: pair <name> <mcp-url> <core-token>")
        }
        let node = NeoYNodeConfiguration(name: tokens[1], url: tokens[2], token: tokens[3])
        guard let url = URL(string: securedURL(node)) else {
            throw NeoYCoreError.invalidCommand("invalid node MCP URL")
        }
        _ = try await rpc(url: url, method: "tools/list", params: [:])
        try await store.upsert(node)
        return NeoYCoreJSON.encode(PublicNode(node))
    }

    private func status(_ node: NeoYNodeConfiguration) async throws -> String {
        guard node.isEnabled, let url = URL(string: securedURL(node)) else {
            throw NeoYCoreError.operationFailed("node '\(node.name)' is disabled or has an invalid URL")
        }
        let result = try await rpc(url: url, method: "tools/list", params: [:])
        let tools = (result as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        struct Status: Codable {
            let name: String
            let url: String
            let reachable: Bool
            let coreTools: [String]
        }
        let names = tools.compactMap { $0["name"] as? String }
            .filter { Self.allowedRemoteCoreTools.contains($0) }
            .sorted()
        return NeoYCoreJSON.encode(Status(name: node.name, url: node.url, reachable: true, coreTools: names))
    }

    private func invoke(_ parsed: NeoYCommandLine.Parsed) async throws -> String {
        guard parsed.tokens.count >= 3 else {
            throw NeoYCoreError.invalidCommand("usage: invoke <node> <core-tool> -- <command>")
        }
        let name = parsed.tokens[1]
        let tool = parsed.tokens[2]
        guard Self.allowedRemoteCoreTools.contains(tool) else {
            throw NeoYCoreError.unauthorized("'\(tool)' is not part of the canonical remote Core contract")
        }
        guard let node = await store.get(name), node.isEnabled,
              let url = URL(string: securedURL(node)) else {
            throw NeoYCoreError.notFound("trusted node '\(name)' not found or disabled")
        }
        let command = parsed.remainder ?? "help"
        let result = try await rpc(url: url, method: "tools/call", params: [
            "name": tool,
            "arguments": ["command": command]
        ])
        struct RemoteResult: Codable {
            let node: String
            let tool: String
            let result: String
        }
        let text: String
        if let object = result as? [String: Any],
           let content = object["content"] as? [[String: Any]],
           let first = content.first,
           let value = first["text"] as? String {
            text = value
        } else {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
            text = String(decoding: data, as: UTF8.self)
        }
        return NeoYCoreJSON.encode(RemoteResult(node: name, tool: tool, result: text))
    }

    private func localIdentity() -> String {
        struct Identity: Codable {
            let host: String
            let bundle: String
            let version: String
            let coreURL: String
        }
        let base = NeoYDeploymentSettingsStore.load().localMCPURL
        return NeoYCoreJSON.encode(Identity(
            host: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            bundle: Bundle.main.bundleIdentifier ?? "com.neox.neoy",
            version: "2.2.0",
            coreURL: NeoYCoreAuth.url(base)
        ))
    }

    private func localToken() -> String {
        struct Token: Codable {
            let token: String
            let localCoreURL: String
            let publicCoreURL: String?
        }
        let settings = NeoYDeploymentSettingsStore.load()
        return NeoYCoreJSON.encode(Token(
            token: NeoYCoreAuth.token(),
            localCoreURL: NeoYCoreAuth.url(settings.localMCPURL),
            publicCoreURL: settings.publicMCPURL.map(NeoYCoreAuth.url)
        ))
    }

    private func securedURL(_ node: NeoYNodeConfiguration) -> String {
        guard var components = URLComponents(string: node.url) else { return node.url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: node.token))
        components.queryItems = items
        return components.string ?? node.url
    }

    private func rpc(url: URL, method: String, params: [String: Any]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "neoy-node",
            "method": method,
            "params": params
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NeoYCoreError.operationFailed("remote node HTTP request failed")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NeoYCoreError.operationFailed("remote node returned invalid JSON")
        }
        if let error = envelope["error"] as? [String: Any] {
            throw NeoYCoreError.operationFailed(error["message"] as? String ?? "remote node error")
        }
        return envelope["result"] ?? NSNull()
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static let help = """
    node — trusted remote NeoY Core forwarding
      local
      token
      discover [--seconds N]
      list
      pair <name> <mcp-url> <core-token>
      remove <name>
      status <name>
      invoke <name> <neoy.setup|mac.exec|mac.fs|codex.threads|node> -- <command>
    Pairing is explicit and stores the remote token in a mode-0600 local file. Remote responses always identify the executing node.
    """
}

enum NeoYNodeTools {
    static func tools(service: NeoYNodeService) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "node",
                description: "Trusted remote NeoY discovery/pairing/status and canonical Core invocation. Call with command='help' for grammar.",
                parameters: NeoYCoreJSON.string("CLI-like remote-node command; use 'help' for grammar")
            ) { arguments in
                try await service.execute(NeoYCoreJSON.command(from: arguments))
            }
        ]
    }
}
