import Darwin
import Foundation

struct NeoYFederatedServerStatus: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let enabled: Bool
    let healthy: Bool
    let exposedTools: [String]
    let exposedResources: [String]
    let error: String?
    let lifecycleState: String
    let processAlive: Bool
    let transportConnected: Bool
    let initialized: Bool
    let toolsListSuccessful: Bool
}

fileprivate extension NeoYFederatedServerStatus {
    static func disabled(_ configuration: NeoYMCPServerConfiguration) -> Self {
        .init(name: configuration.name, url: configuration.url, enabled: false, healthy: true,
              exposedTools: [], exposedResources: [], error: nil, lifecycleState: "disabled",
              processAlive: false, transportConnected: false, initialized: false, toolsListSuccessful: false)
    }

    static func unavailable(_ configuration: NeoYMCPServerConfiguration, _ error: String,
                            lifecycleState: String = "unhealthy") -> Self {
        .init(name: configuration.name, url: configuration.url, enabled: configuration.isEnabled, healthy: false,
              exposedTools: [], exposedResources: [], error: error, lifecycleState: lifecycleState,
              processAlive: false, transportConnected: false, initialized: false, toolsListSuccessful: false)
    }
}

struct NeoYRemoteTool: Sendable {
    let name: String
    let descriptor: JSONValue
}

struct NeoYRemoteResource: Sendable {
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

struct NeoYMCPStdioSnapshot: Sendable {
    let tools: [NeoYRemoteTool]
    let resources: [NeoYRemoteResource]
}

enum NeoYMCPStdioEvent: Sendable {
    case exited(String)
    case restarting(Int, String)
    case ready(NeoYMCPStdioSnapshot)
}

private struct NeoYSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

actor NeoYMCPStdioClient {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let retryDelays: [Duration]
    private let requestTimeout: Duration
    private let onEvent: @Sendable (NeoYMCPStdioEvent) async -> Void
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()
    private var pending: [String: CheckedContinuation<NeoYSendableBox<[String: Any]>, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var processGeneration: UUID?
    private var readyGeneration: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var stopping = false

    init(executable: String, arguments: [String], environment: [String: String] = [:],
         retryDelays: [Duration] = [.zero, .milliseconds(250), .seconds(1), .seconds(5)],
         requestTimeout: Duration = .seconds(660),
         onEvent: @escaping @Sendable (NeoYMCPStdioEvent) async -> Void = { _ in }) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.retryDelays = retryDelays.isEmpty ? [.seconds(5)] : retryDelays
        self.requestTimeout = requestTimeout
        self.onEvent = onEvent
    }

    static func from(url: URL, environment: [String: String] = [:],
                     onEvent: @escaping @Sendable (NeoYMCPStdioEvent) async -> Void = { _ in }) throws -> NeoYMCPStdioClient {
        guard url.scheme?.lowercased() == "stdio",
              url.path.hasPrefix("/"),
              !url.path.isEmpty else {
            throw NeoYRuntimeControlError.federation("invalid stdio MCP URL")
        }
        let arguments = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .filter { $0.name == "arg" }
            .compactMap(\.value) ?? []
        return NeoYMCPStdioClient(executable: url.path, arguments: arguments,
                                  environment: environment, onEvent: onEvent)
    }

    func connect() async throws -> NeoYMCPStdioSnapshot {
        stopping = false
        do { return try await startAndProbe() }
        catch {
            failAndRecover(error)
            throw error
        }
    }

    func readResource(uri: String) async throws -> String {
        let result = try await rpc(method: "resources/read", params: ["uri": uri])
        return try encodeFederatedResult(result)
    }

    func call(name: String, arguments: JSONValue) async throws -> String {
        let result = try await rpc(
            method: "tools/call",
            params: ["name": name, "arguments": arguments.anyJSON]
        )
        return try encodeFederatedResult(result)
    }

    func stop() {
        stopping = true
        recoveryTask?.cancel()
        recoveryTask = nil
        discardCurrentProcess()
    }

    func processIdentifier() -> Int32? {
        guard process?.isRunning == true, readyGeneration == processGeneration else { return nil }
        return process?.processIdentifier
    }

    private func startAndProbe() async throws -> NeoYMCPStdioSnapshot {
        if process?.isRunning == true {
            let tools = try decodeTools(await rawRPC(method: "tools/list", params: [:]))
            let resources = (try? await rawRPC(method: "resources/list", params: [:])).map(decodeResources) ?? []
            readyGeneration = processGeneration
            return .init(tools: tools, resources: resources)
        }

        discardCurrentProcess()
        let generation = UUID()
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = NeoYProcessEnvironment.childEnvironment().merging(environment) { _, supplied in supplied }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            let reason = terminated.terminationReason == .uncaughtSignal ? "signal" : "exit"
            Task { await self?.processExited(generation: generation, detail: "\(reason)=\(code)") }
        }

        do { try process.run() }
        catch {
            throw NeoYRuntimeControlError.federation(
                "could not launch stdio MCP '\(executable)': \(error.localizedDescription)"
            )
        }

        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        self.output = stdoutPipe.fileHandleForReading
        self.processGeneration = generation
        self.readBuffer.removeAll(keepingCapacity: false)
        self.output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.received(data, generation: generation) }
        }

        do {
            _ = try await rawRPC(
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
            let tools = try decodeTools(await rawRPC(method: "tools/list", params: [:]))
            let resources = (try? await rawRPC(method: "resources/list", params: [:])).map(decodeResources) ?? []
            readyGeneration = generation
            return .init(tools: tools, resources: resources)
        } catch {
            discardCurrentProcess()
            throw error
        }
    }

    private func rpc(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true else {
            throw NeoYRuntimeControlError.federation("stdio MCP process is not running")
        }
        return try await rawRPC(method: method, params: params)
    }

    private func rawRPC(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        let generation = processGeneration
        let boxed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send([
                        "jsonrpc": "2.0",
                        "id": id,
                        "method": method,
                        "params": params,
                    ])
                } catch {
                    failAndRecover(error)
                    return
                }
                let timeout = requestTimeout
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.requestTimedOut(id: id, generation: generation)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
        return boxed.value
    }

    private func send(_ object: [String: Any]) throws {
        guard let input else {
            throw NeoYRuntimeControlError.federation("stdio MCP input is unavailable")
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do { try input.write(contentsOf: data) }
        catch {
            throw NeoYRuntimeControlError.federation(
                "stdio MCP write failed: \(error.localizedDescription)"
            )
        }
    }

    private func received(_ data: Data, generation: UUID) {
        guard processGeneration == generation else { return }
        guard !data.isEmpty else {
            failAndRecover(NeoYRuntimeControlError.federation("stdio MCP closed its output"))
            return
        }
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                failAndRecover(NeoYRuntimeControlError.federation("stdio MCP response is not JSON"))
                return
            }
            guard let id = message["id"] as? String, let continuation = pending.removeValue(forKey: id) else { continue }
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: NeoYRuntimeControlError.federation(
                    "stdio MCP error: \(error["message"] ?? error)"
                ))
            } else if let result = message["result"] as? [String: Any] {
                continuation.resume(returning: NeoYSendableBox(value: result))
            } else {
                continuation.resume(throwing: NeoYRuntimeControlError.federation("stdio MCP response has no result"))
            }
        }
    }

    private func cancelRequest(id: String) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func requestTimedOut(id: String, generation: UUID?) {
        guard pending[id] != nil, processGeneration == generation else { return }
        failAndRecover(NeoYRuntimeControlError.federation("stdio MCP request timed out"))
    }

    private func processExited(generation: UUID, detail: String) async {
        guard processGeneration == generation, !stopping else { return }
        discardCurrentProcess(terminate: false)
        scheduleRecovery(initialError: detail, exitedDetail: detail)
    }

    private func failAndRecover(_ error: Error) {
        let detail = error.localizedDescription
        let hadProcess = processGeneration != nil
        discardCurrentProcess()
        scheduleRecovery(initialError: detail, exitedDetail: hadProcess ? detail : nil)
    }

    private func scheduleRecovery(initialError: String = "provider unavailable", exitedDetail: String? = nil) {
        guard !stopping, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            if let exitedDetail { await self.onEvent(.exited(exitedDetail)) }
            await self.recover(initialError: initialError)
        }
    }

    private func recover(initialError: String) async {
        var attempt = 0
        var lastError = initialError
        defer { recoveryTask = nil }
        while !Task.isCancelled, !stopping {
            let delay = retryDelays[min(attempt, retryDelays.count - 1)]
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, !stopping else { return }
            attempt += 1
            await onEvent(.restarting(attempt, lastError))
            do {
                let snapshot = try await startAndProbe()
                await onEvent(.ready(snapshot))
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func discardCurrentProcess(terminate: Bool = true) {
        let current = process
        let failure = NeoYRuntimeControlError.federation(stopping ? "stdio MCP stopped" : "stdio MCP connection reset")
        processGeneration = nil
        readyGeneration = nil
        process = nil
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        readBuffer.removeAll(keepingCapacity: false)
        let continuations = pending.values
        pending.removeAll()
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        for continuation in continuations { continuation.resume(throwing: failure) }
        if terminate, let current, current.isRunning {
            let pid = current.processIdentifier
            current.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
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
    private var stdioTokens: [String: UUID] = [:]

    init(server: MCPServer) {
        self.server = server
    }

    func reconcile(_ configurations: [NeoYMCPServerConfiguration]) async {
        let desiredNames = Set(configurations.map(\.name))
        let knownNames = Set(exposedByServer.keys).union(resourcesByServer.keys).union(stdioClients.keys)
        for name in knownNames where !desiredNames.contains(name) {
            await clear(name)
            statusesByServer.removeValue(forKey: name)
        }

        for configuration in configurations {
            await clear(configuration.name)
            guard configuration.isEnabled else {
                statusesByServer[configuration.name] = .disabled(configuration)
                continue
            }
            guard let url = URL(string: configuration.url),
                  let scheme = url.scheme?.lowercased() else {
                statusesByServer[configuration.name] = .unavailable(configuration, "invalid URL")
                continue
            }

            do {
                switch scheme {
                case "http", "https":
                    let tools = try await NeoYMCPHTTPClient.tools(url: url)
                    let resources = await NeoYMCPHTTPClient.resources(url: url)
                    publish(
                        configuration: configuration, tools: tools, resources: resources, processAlive: false,
                        invoke: { name, arguments in
                            try await NeoYMCPHTTPClient.call(url: url, name: name, arguments: arguments)
                        },
                        readResource: { uri in
                            try await NeoYMCPHTTPClient.readResource(url: url, uri: uri)
                        }
                    )
                case "stdio":
                    let token = UUID()
                    stdioTokens[configuration.name] = token
                    let environment = configuration.name == NeoYBundledRuntime.coreProviderName
                        ? NeoYBundledRuntime.coreEnvironment : [:]
                    let client = try NeoYMCPStdioClient.from(url: url, environment: environment) { [weak self] event in
                        await self?.handleStdioEvent(event, configuration: configuration, token: token)
                    }
                    stdioClients[configuration.name] = client
                    NSLog("NeoY stdio provider starting: %@", configuration.name)
                    let snapshot = try await client.connect()
                    publish(configuration: configuration, snapshot: snapshot, client: client)
                    NSLog("NeoY stdio provider ready: %@", configuration.name)
                default:
                    throw NeoYRuntimeControlError.federation("unsupported MCP transport '\(scheme)'")
                }
            } catch {
                if scheme == "stdio", stdioClients[configuration.name] != nil {
                    statusesByServer[configuration.name] = .unavailable(
                        configuration, error.localizedDescription, lifecycleState: "restarting")
                } else {
                    statusesByServer[configuration.name] = .unavailable(configuration, error.localizedDescription)
                }
            }
        }
    }

    func statuses(configurations: [NeoYMCPServerConfiguration]) -> [NeoYFederatedServerStatus] {
        configurations.sorted { $0.name < $1.name }.map {
            statusesByServer[$0.name] ?? .init(
                name: $0.name, url: $0.url, enabled: $0.isEnabled,
                healthy: !$0.isEnabled, exposedTools: [], exposedResources: [], error: $0.isEnabled ? "not reconciled" : nil,
                lifecycleState: $0.isEnabled ? "starting" : "disabled", processAlive: false,
                transportConnected: false, initialized: false, toolsListSuccessful: false)
        }
    }

    func stdioProcessIdentifier(_ name: String) async -> Int32? {
        await stdioClients[name]?.processIdentifier()
    }

    func stop() {
        for name in Set(exposedByServer.keys).union(resourcesByServer.keys) { unregister(name) }
        let clients = Array(stdioClients.values)
        stdioClients.removeAll()
        stdioTokens.removeAll()
        for client in clients { Task { await client.stop() } }
        statusesByServer.removeAll()
    }

    private func clear(_ name: String) async {
        stdioTokens.removeValue(forKey: name)
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

    private func handleStdioEvent(_ event: NeoYMCPStdioEvent,
                                  configuration: NeoYMCPServerConfiguration, token: UUID) async {
        guard stdioTokens[configuration.name] == token,
              let client = stdioClients[configuration.name] else { return }
        switch event {
        case .exited(let detail):
            unregister(configuration.name)
            statusesByServer[configuration.name] = .unavailable(configuration, detail, lifecycleState: "unhealthy")
            NSLog("NeoY stdio child exited unexpectedly: %@ %@", configuration.name, detail)
        case .restarting(let attempt, let detail):
            unregister(configuration.name)
            statusesByServer[configuration.name] = .unavailable(
                configuration, detail, lifecycleState: "restarting")
            NSLog("NeoY stdio provider restarting: %@ attempt=%d", configuration.name, attempt)
        case .ready(let snapshot):
            unregister(configuration.name)
            publish(configuration: configuration, snapshot: snapshot, client: client)
            NSLog("NeoY stdio provider ready: %@", configuration.name)
        }
    }

    private func publish(configuration: NeoYMCPServerConfiguration,
                         snapshot: NeoYMCPStdioSnapshot, client: NeoYMCPStdioClient) {
        publish(
            configuration: configuration, tools: snapshot.tools, resources: snapshot.resources, processAlive: true,
            invoke: { name, arguments in try await client.call(name: name, arguments: arguments) },
            readResource: { uri in try await client.readResource(uri: uri) }
        )
    }

    private func publish(configuration: NeoYMCPServerConfiguration,
                         tools: [NeoYRemoteTool], resources: [NeoYRemoteResource], processAlive: Bool,
                         invoke: @escaping @Sendable (String, JSONValue) async throws -> String,
                         readResource: @escaping @Sendable (String) async throws -> String) {
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
        if configuration.name == NeoYBundledRuntime.coreProviderName {
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
        } else if configuration.name != NeoYBundledRuntime.legacyMacBridgeProviderName, !tools.isEmpty {
            let facadeName = configuration.name == "events" ? "events" : "mcp.\(configuration.name)"
            let rewritten = tools.map { tool in
                NeoYRemoteTool(name: tool.name, descriptor: rewriteToolResourceMetadata(tool.descriptor, provider: configuration.name))
            }
            let descriptor = federatedCommandFacadeDescriptor(provider: configuration.name)
            let facadeTools = rewritten.filter { !isAppOnlyTool($0.descriptor) }
            let rewrittenInvoke: @Sendable (String, JSONValue) async throws -> String = { name, arguments in
                try rewriteFederatedToolResult(
                    try await invoke(name, arguments),
                    provider: configuration.name
                )
            }
            server.registerFederatedTool(descriptor: descriptor, name: facadeName, protected: true,
                                         provider: configuration.name) { arguments in
                try await dispatchFederatedCommandFacade(
                    provider: configuration.name, tools: facadeTools, arguments: arguments, invoke: rewrittenInvoke
                )
            }
            names.append(facadeName)

            // MCP Apps need the child tool's descriptor metadata at the public
            // boundary so the host can discover and render its resource. Keep
            // ordinary commands behind the compact facade.
            for tool in rewritten where hasMCPAppUIMetadata(tool.descriptor) || isAppOnlyTool(tool.descriptor) {
                let directName = directFederatedToolName(provider: configuration.name, child: tool.name)
                server.registerFederatedTool(descriptor: tool.descriptor, name: directName, protected: true,
                                             provider: configuration.name) { arguments in
                    try await rewrittenInvoke(tool.name, arguments)
                }
                names.append(directName)
            }
        }
        exposedByServer[configuration.name] = names
        resourcesByServer[configuration.name] = resourceURIs
        statusesByServer[configuration.name] = .init(
            name: configuration.name, url: configuration.url, enabled: true, healthy: true,
            exposedTools: names.sorted(), exposedResources: resourceURIs.sorted(), error: nil,
            lifecycleState: "ready", processAlive: processAlive, transportConnected: true,
            initialized: true, toolsListSuccessful: true)
    }
}


private func federatedCommandFacadeDescriptor(provider: String) -> JSONValue {
    .object([
        "description": .string("Commands exposed by federated MCP provider \(provider). Use command='help' to list subcommands or inspect one subcommand's exact args schema."),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Remote subcommand name, or 'help'."),
                ]),
                "args": .object([
                    "type": .string("object"),
                    "description": .string("Arguments for the selected subcommand. Use help for the exact schema."),
                ]),
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false),
        ]),
    ])
}

private func dispatchFederatedCommandFacade(
    provider: String,
    tools: [NeoYRemoteTool],
    arguments: JSONValue,
    invoke: @escaping @Sendable (String, JSONValue) async throws -> String
) async throws -> String {
    guard case .object(let object) = arguments,
          case .string(let requested)? = object["command"] else {
        throw NeoYRuntimeControlError.federation("command is required")
    }
    let args = object["args"] ?? .object([:])
    guard case .object = args else {
        throw NeoYRuntimeControlError.federation("args must be an object")
    }
    let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    if requested == "help" {
        let named: String?
        if case .object(let helpArgs) = args, case .string(let value)? = helpArgs["command"] { named = value }
        else { named = nil }
        if let named {
            guard let tool = byName[named] else {
                throw NeoYRuntimeControlError.federation("Unknown \(provider) command '\(named)'")
            }
            let description = descriptorField(tool.descriptor, "description") ?? .string("")
            let schema = descriptorField(tool.descriptor, "inputSchema") ?? .object(["type": .string("object")])
            return encodeJSONValue(.object([
                "command": .string(named),
                "description": description,
                "schema": schema,
            ]))
        }
        let rows: [JSONValue] = tools.sorted { $0.name < $1.name }.map { tool in
            .object([
                "command": .string(tool.name),
                "description": descriptorField(tool.descriptor, "description") ?? .string(""),
            ])
        }
        return encodeJSONValue(.object(["commands": .array(rows)]))
    }
    guard let tool = byName[requested] else {
        throw NeoYRuntimeControlError.federation("Unknown \(provider) command '\(requested)'")
    }
    return try await invoke(tool.name, args)
}

private func descriptorField(_ descriptor: JSONValue, _ key: String) -> JSONValue? {
    guard case .object(let object) = descriptor else { return nil }
    return object[key]
}

private func encodeJSONValue(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
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
    if case .string(let uri)? = meta["ui/resourceUri"] {
        meta["ui/resourceUri"] = .string(proxyFederatedResourceURI(provider: provider, original: uri))
    }
    if case .string(let uri)? = meta["openai/outputTemplate"] {
        meta["openai/outputTemplate"] = .string(proxyFederatedResourceURI(provider: provider, original: uri))
    }
    object["_meta"] = .object(meta)
    return .object(object)
}

private func directFederatedToolName(provider: String, child: String) -> String {
    child.hasPrefix("\(provider).") ? child : "\(provider).\(child)"
}

private func hasMCPAppUIMetadata(_ descriptor: JSONValue) -> Bool {
    guard case .object(let object) = descriptor,
          case .object(let meta)? = object["_meta"] else { return false }
    if case .object(let ui)? = meta["ui"], case .string = ui["resourceUri"] {
        return true
    }
    if case .string = meta["ui/resourceUri"] {
        return true
    }
    if case .string = meta["openai/outputTemplate"] {
        return true
    }
    return false
}

private func isAppOnlyTool(_ descriptor: JSONValue) -> Bool {
    guard case .object(let object) = descriptor,
          case .object(let meta)? = object["_meta"],
          case .object(let ui)? = meta["ui"],
          case .array(let visibility)? = ui["visibility"] else { return false }
    return visibility.contains { $0 == .string("app") }
}

private func rewriteFederatedToolResult(_ encoded: String, provider: String) throws -> String {
    guard encoded.hasPrefix(federatedResultPrefix),
          let data = Data(base64Encoded: String(encoded.dropFirst(federatedResultPrefix.count))),
          var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NeoYRuntimeControlError.federation("remote tool result is invalid")
    }

    if var meta = result["_meta"] as? [String: Any] {
        if var ui = meta["ui"] as? [String: Any], let uri = ui["resourceUri"] as? String {
            ui["resourceUri"] = proxyFederatedResourceURI(provider: provider, original: uri)
            meta["ui"] = ui
        }
        if let uri = meta["ui/resourceUri"] as? String {
            meta["ui/resourceUri"] = proxyFederatedResourceURI(provider: provider, original: uri)
        }
        if let uri = meta["openai/outputTemplate"] as? String {
            meta["openai/outputTemplate"] = proxyFederatedResourceURI(provider: provider, original: uri)
        }
        result["_meta"] = meta
    }

    if var structuredContent = result["structuredContent"] as? [String: Any],
       let uri = structuredContent["resourceUri"] as? String {
        structuredContent["resourceUri"] = proxyFederatedResourceURI(provider: provider, original: uri)
        result["structuredContent"] = structuredContent
    }
    return try encodeFederatedResult(result)
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
