import Foundation

struct NeoYFederatedServerStatus: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let enabled: Bool
    let healthy: Bool
    let exposedTools: [String]
    let error: String?
}

fileprivate struct NeoYRemoteTool: Sendable {
    let name: String
    let description: String?
    let schema: JSONValue?
}

enum NeoYMCPRemoteClient {
    fileprivate static func tools(url: URL) async throws -> [NeoYRemoteTool] {
        let result = try await rpc(url: url, method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else {
            throw NeoYRuntimeControlError.federation("remote tools/list returned no tools")
        }
        return tools.compactMap { value in
            guard let name = value["name"] as? String else { return nil }
            return NeoYRemoteTool(
                name: name,
                description: value["description"] as? String,
                schema: value["inputSchema"].map(JSONValue.from(any:))
            )
        }
    }

    static func call(url: URL, name: String, arguments: JSONValue) async throws -> String {
        let result = try await rpc(
            url: url,
            method: "tools/call",
            params: ["name": name, "arguments": arguments.anyJSON]
        )
        guard let content = result["content"] as? [[String: Any]] else {
            throw NeoYRuntimeControlError.federation("remote tool returned no content")
        }
        if result["isError"] as? Bool == true {
            let message = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            throw NeoYRuntimeControlError.federation(message.isEmpty ? "remote tool failed" : message)
        }
        if let text = content.compactMap({ $0["text"] as? String }).first { return text }
        throw NeoYRuntimeControlError.federation("federated image/binary tool results are not exposed by NeoY v2")
    }

    private static func rpc(url: URL, method: String, params: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NeoYRuntimeControlError.federation("remote MCP HTTP request failed")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NeoYRuntimeControlError.federation("remote MCP response is not JSON")
        }
        if let error = object["error"] as? [String: Any] {
            throw NeoYRuntimeControlError.federation("remote MCP error: \(error["message"] ?? error)")
        }
        guard let result = object["result"] as? [String: Any] else {
            throw NeoYRuntimeControlError.federation("remote MCP response has no result")
        }
        return result
    }
}

@MainActor
final class NeoYMCPFederation {
    private let server: MCPServer
    private var exposedByServer: [String: [String]] = [:]
    private var statusesByServer: [String: NeoYFederatedServerStatus] = [:]

    init(server: MCPServer) {
        self.server = server
    }

    func reconcile(_ configurations: [NeoYMCPServerConfiguration]) async {
        let desiredNames = Set(configurations.map(\.name))
        for name in Array(exposedByServer.keys) where !desiredNames.contains(name) {
            unregister(name)
            statusesByServer.removeValue(forKey: name)
        }

        for configuration in configurations {
            unregister(configuration.name)
            guard configuration.isEnabled else {
                statusesByServer[configuration.name] = .init(
                    name: configuration.name, url: configuration.url, enabled: false,
                    healthy: true, exposedTools: [], error: nil)
                continue
            }
            guard let url = URL(string: configuration.url) else {
                statusesByServer[configuration.name] = failed(configuration, "invalid URL")
                continue
            }
            do {
                let tools = try await NeoYMCPRemoteClient.tools(url: url)
                var names: [String] = []
                for tool in tools {
                    let localName = "mcp.\(configuration.name).\(tool.name)"
                    server.register(tools: [ToolDefinition(
                        name: localName,
                        description: "[\(configuration.name)] \(tool.description ?? tool.name)",
                        parameters: tool.schema
                    ) { arguments in
                        try await NeoYMCPRemoteClient.call(url: url, name: tool.name, arguments: arguments)
                    }], protected: true)
                    names.append(localName)
                }
                exposedByServer[configuration.name] = names
                statusesByServer[configuration.name] = .init(
                    name: configuration.name, url: configuration.url, enabled: true,
                    healthy: true, exposedTools: names.sorted(), error: nil)
            } catch {
                statusesByServer[configuration.name] = failed(configuration, error.localizedDescription)
            }
        }
    }

    func statuses(configurations: [NeoYMCPServerConfiguration]) -> [NeoYFederatedServerStatus] {
        configurations.sorted { $0.name < $1.name }.map {
            statusesByServer[$0.name] ?? .init(
                name: $0.name, url: $0.url, enabled: $0.isEnabled,
                healthy: !$0.isEnabled, exposedTools: [], error: $0.isEnabled ? "not reconciled" : nil)
        }
    }

    func stop() {
        for name in Array(exposedByServer.keys) { unregister(name) }
        statusesByServer.removeAll()
    }

    private func unregister(_ name: String) {
        for tool in exposedByServer.removeValue(forKey: name) ?? [] {
            server.unregister(name: tool)
        }
    }

    private func failed(_ configuration: NeoYMCPServerConfiguration, _ error: String) -> NeoYFederatedServerStatus {
        .init(
            name: configuration.name, url: configuration.url, enabled: configuration.isEnabled,
            healthy: false, exposedTools: [], error: error)
    }
}

private extension JSONValue {
    static func from(any: Any) -> JSONValue {
        switch any {
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as Int: .int(value)
        case let value as Double: .double(value)
        case let value as [Any]: .array(value.map { .from(any: $0) })
        case let value as [String: Any]: .object(value.mapValues { .from(any: $0) })
        default: .null
        }
    }
}
