import Foundation

struct NeoYFederatedServerStatus: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let enabled: Bool
    let healthy: Bool
    let exposedTools: [String]
    let exposedResources: [String]
    let error: String?
}

fileprivate struct NeoYRemoteTool: Sendable {
    let name: String
    let descriptor: JSONValue
}

fileprivate struct NeoYRemoteResource: Sendable {
    let uri: String
    let descriptor: JSONValue
}

enum NeoYMCPHTTPClient {
    fileprivate static func tools(url: URL) async throws -> [NeoYRemoteTool] {
        let result = try await rpc(url: url, method: "tools/list", params: [:])
        return try decodeTools(result)
    }

    fileprivate static func resources(url: URL) async -> [NeoYRemoteResource] {
        do {
            let result = try await rpc(url: url, method: "resources/list", params: [:])
            return decodeResources(result)
        } catch {
            return []
        }
    }

    static func readResource(url: URL, uri: String) async throws -> String {
        let result = try await rpc(url: url, method: "resources/read", params: ["uri": uri])
        return try encodeFederatedResult(result)
    }

    static func call(url: URL, name: String, arguments: JSONValue) async throws -> String {
        let result = try await rpc(
            url: url,
            method: "tools/call",
            params: ["name": name, "arguments": arguments.anyJSON]
        )
        return try encodeFederatedResult(result)
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
        return try decodeRPC(data)
    }
}

actor NeoYMCPStdioClient {
    private let executable: String
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()

    init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    static func from(url: URL) throws -> NeoYMCPStdioClient {
        guard url.scheme?.lowercased() == "stdio",
              url.path.hasPrefix("/"),
              !url.path.isEmpty else {
            throw NeoYRuntimeControlError.federation("invalid stdio MCP URL")
        }
        let arguments = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "arg" }
            .compactMap(\.value) ?? []
        return NeoYMCPStdioClient(executable: url.path, arguments: arguments)
    }

    fileprivate func tools() throws -> [NeoYRemoteTool] {
        let result = try rpc(method: "tools/list", params: [:])
        return try decodeTools(result)
    }

    fileprivate func resources() -> [NeoYRemoteResource] {
        do {
            let result = try rpc(method: "resources/list", params: [:])
            return decodeResources(result)
        } catch {
            return []
        }
    }

    func readResource(uri: String) throws -> String {
        let result = try rpc(method: "resources/read", params: ["uri": uri])
        return try encodeFederatedResult(result)
    }

    func call(name: String, arguments: JSONValue) throws -> String {
        let result = try rpc(
            method: "tools/call",
            params: ["name": name, "arguments": arguments.anyJSON]
        )
        return try encodeFederatedResult(result)
    }

    func stop() {
        if process?.isRunning == true { process?.terminate() }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func ensureStarted() throws {
        if process?.isRunning == true { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = NeoYProcessEnvironment.childEnvironment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() }
        catch {
            throw NeoYRuntimeControlError.federation(
                "could not launch stdio MCP '\(executable)': \(error.localizedDescription)"
            )
        }

        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdoutPipe.fileHandleForReading
        self.readBuffer.removeAll(keepingCapacity: false)

        _ = try rawRPC(
            method: "initialize",
            params: [
                "protocolVersion": "2025-06-18",
                "capabilities": [:],
                "clientInfo": ["name": "neoy-federation", "version": NeoYCoreRuntime.version],
            ]
        )
        try send([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:],
        ])
    }

    private func rpc(method: String, params: [String: Any]) throws -> [String: Any] {
        try ensureStarted()
        return try rawRPC(method: method, params: params)
    }

    private func rawRPC(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = UUID().uuidString
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])
        while true {
            let message = try readMessage()
            guard let responseID = message["id"] as? String, responseID == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw NeoYRuntimeControlError.federation(
                    "stdio MCP error: \(error["message"] ?? error)"
                )
            }
            guard let result = message["result"] as? [String: Any] else {
                throw NeoYRuntimeControlError.federation("stdio MCP response has no result")
            }
            return result
        }
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else {
            throw NeoYRuntimeControlError.federation("stdio MCP input is unavailable")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do { try input.write(contentsOf: data) }
        catch {
            stop()
            throw NeoYRuntimeControlError.federation(
                "stdio MCP write failed: \(error.localizedDescription)"
            )
        }
    }

    private func readMessage() throws -> [String: Any] {
        guard let output else {
            throw NeoYRuntimeControlError.federation("stdio MCP output is unavailable")
        }
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw NeoYRuntimeControlError.federation("stdio MCP response is not JSON")
                }
                return object
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                stop()
                throw NeoYRuntimeControlError.federation("stdio MCP closed its output")
            }
            readBuffer.append(chunk)
        }
    }
}

@MainActor
final class NeoYMCPFederation {
    private let server: MCPServer
    private var exposedByServer: [String: [String]] = [:]
    private var resourcesByServer: [String: [String]] = [:]
    private var statusesByServer: [String: NeoYFederatedServerStatus] = [:]
    private var stdioClients: [String: NeoYMCPStdioClient] = [:]

    init(server: MCPServer) {
        self.server = server
    }

    func reconcile(_ configurations: [NeoYMCPServerConfiguration]) async {
        let desiredNames = Set(configurations.map(\.name))
        for name in Set(exposedByServer.keys).union(resourcesByServer.keys) where !desiredNames.contains(name) {
            await clear(name)
            statusesByServer.removeValue(forKey: name)
        }

        for configuration in configurations {
            await clear(configuration.name)
            guard configuration.isEnabled else {
                statusesByServer[configuration.name] = .init(
                    name: configuration.name, url: configuration.url, enabled: false,
                    healthy: true, exposedTools: [], exposedResources: [], error: nil)
                continue
            }
            guard let url = URL(string: configuration.url),
                  let scheme = url.scheme?.lowercased() else {
                statusesByServer[configuration.name] = failed(configuration, "invalid URL")
                continue
            }

            do {
                let tools: [NeoYRemoteTool]
                let resources: [NeoYRemoteResource]
                let invoke: @Sendable (String, JSONValue) async throws -> String
                let readResource: @Sendable (String) async throws -> String

                switch scheme {
                case "http", "https":
                    tools = try await NeoYMCPHTTPClient.tools(url: url)
                    resources = await NeoYMCPHTTPClient.resources(url: url)
                    invoke = { name, arguments in
                        try await NeoYMCPHTTPClient.call(url: url, name: name, arguments: arguments)
                    }
                    readResource = { uri in
                        try await NeoYMCPHTTPClient.readResource(url: url, uri: uri)
                    }
                case "stdio":
                    let client = try NeoYMCPStdioClient.from(url: url)
                    tools = try await client.tools()
                    resources = await client.resources()
                    stdioClients[configuration.name] = client
                    invoke = { name, arguments in
                        try await client.call(name: name, arguments: arguments)
                    }
                    readResource = { uri in
                        try await client.readResource(uri: uri)
                    }
                default:
                    throw NeoYRuntimeControlError.federation("unsupported MCP transport '\(scheme)'")
                }


                var resourceURIs: [String] = []
                for resource in resources {
                    let proxied = proxyFederatedResourceURI(provider: configuration.name, original: resource.uri)
                    var descriptor = resource.descriptor
                    if case .object(var object) = descriptor {
                        object["uri"] = .string(proxied)
                        descriptor = .object(object)
                    }
                    server.registerFederatedResource(descriptor: descriptor, uri: proxied) { _ in
                        let result = try await readResource(resource.uri)
                        return try rewriteFederatedResourceResult(result, provider: configuration.name)
                    }
                    resourceURIs.append(proxied)
                }

                var names: [String] = []
                for tool in tools {
                    guard let localName = NeoYBundledRuntime.exposedToolName(
                        provider: configuration.name, tool: tool.name
                    ) else { continue }
                    let descriptor = rewriteToolResourceMetadata(tool.descriptor, provider: configuration.name)
                    server.registerFederatedTool(descriptor: descriptor, name: localName, protected: true) { arguments in
                        try await invoke(tool.name, arguments)
                    }
                    names.append(localName)
                }
                exposedByServer[configuration.name] = names
                resourcesByServer[configuration.name] = resourceURIs
                statusesByServer[configuration.name] = .init(
                    name: configuration.name, url: configuration.url, enabled: true,
                    healthy: true, exposedTools: names.sorted(), exposedResources: resourceURIs.sorted(), error: nil)
            } catch {
                if let client = stdioClients.removeValue(forKey: configuration.name) {
                    await client.stop()
                }
                statusesByServer[configuration.name] = failed(configuration, error.localizedDescription)
            }
        }
    }

    func statuses(configurations: [NeoYMCPServerConfiguration]) -> [NeoYFederatedServerStatus] {
        configurations.sorted { $0.name < $1.name }.map {
            statusesByServer[$0.name] ?? .init(
                name: $0.name, url: $0.url, enabled: $0.isEnabled,
                healthy: !$0.isEnabled, exposedTools: [], exposedResources: [], error: $0.isEnabled ? "not reconciled" : nil)
        }
    }

    func stop() {
        for name in Set(exposedByServer.keys).union(resourcesByServer.keys) { unregister(name) }
        let clients = Array(stdioClients.values)
        stdioClients.removeAll()
        for client in clients { Task { await client.stop() } }
        statusesByServer.removeAll()
    }

    private func clear(_ name: String) async {
        unregister(name)
        if let client = stdioClients.removeValue(forKey: name) {
            await client.stop()
        }
    }

    private func unregister(_ name: String) {
        for tool in exposedByServer.removeValue(forKey: name) ?? [] {
            server.unregister(name: tool)
        }
        for uri in resourcesByServer.removeValue(forKey: name) ?? [] {
            server.unregisterResource(uri: uri)
        }
    }

    private func failed(_ configuration: NeoYMCPServerConfiguration, _ error: String) -> NeoYFederatedServerStatus {
        .init(
            name: configuration.name, url: configuration.url, enabled: configuration.isEnabled,
            healthy: false, exposedTools: [], exposedResources: [], error: error)
    }
}

private func decodeTools(_ result: [String: Any]) throws -> [NeoYRemoteTool] {
    guard let tools = result["tools"] as? [[String: Any]] else {
        throw NeoYRuntimeControlError.federation("remote tools/list returned no tools")
    }
    return tools.compactMap { value in
        guard let name = value["name"] as? String else { return nil }
        return NeoYRemoteTool(name: name, descriptor: .from(any: value))
    }
}

private func decodeResources(_ result: [String: Any]) -> [NeoYRemoteResource] {
    guard let resources = result["resources"] as? [[String: Any]] else { return [] }
    return resources.compactMap { value in
        guard let uri = value["uri"] as? String, !uri.isEmpty else { return nil }
        return NeoYRemoteResource(uri: uri, descriptor: .from(any: value))
    }
}

private func proxyFederatedResourceURI(provider: String, original: String) -> String {
    let encoded = Data(original.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return original.hasPrefix("ui://")
        ? "ui://\(provider)/\(encoded)"
        : "mcp-federation://\(provider)/\(encoded)"
}

private func rewriteToolResourceMetadata(_ descriptor: JSONValue, provider: String) -> JSONValue {
    guard case .object(var object) = descriptor else { return descriptor }
    guard case .object(var meta)? = object["_meta"] else { return .object(object) }
    if case .object(var ui)? = meta["ui"], case .string(let uri)? = ui["resourceUri"] {
        ui["resourceUri"] = .string(proxyFederatedResourceURI(provider: provider, original: uri))
        meta["ui"] = .object(ui)
    }
    if case .string(let uri)? = meta["openai/outputTemplate"] {
        meta["openai/outputTemplate"] = .string(proxyFederatedResourceURI(provider: provider, original: uri))
    }
    object["_meta"] = .object(meta)
    return .object(object)
}

private func rewriteFederatedResourceResult(_ encoded: String, provider: String) throws -> String {
    guard encoded.hasPrefix(federatedResultPrefix),
          let data = Data(base64Encoded: String(encoded.dropFirst(federatedResultPrefix.count))),
          var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NeoYRuntimeControlError.federation("remote resource result is invalid")
    }
    if var contents = result["contents"] as? [[String: Any]] {
        for index in contents.indices {
            if let uri = contents[index]["uri"] as? String {
                contents[index]["uri"] = proxyFederatedResourceURI(provider: provider, original: uri)
            }
        }
        result["contents"] = contents
    }
    return try encodeFederatedResult(result)
}

private let federatedResultPrefix = "mcpresult:"

private func encodeFederatedResult(_ result: [String: Any]) throws -> String {
    guard JSONSerialization.isValidJSONObject(result) else {
        throw NeoYRuntimeControlError.federation("remote MCP result is not JSON serializable")
    }
    let data = try JSONSerialization.data(withJSONObject: result)
    return federatedResultPrefix + data.base64EncodedString()
}

private func decodeRPC(_ data: Data) throws -> [String: Any] {
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
