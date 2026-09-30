import Foundation

enum NeoYSetupTopic: String, CaseIterable, Sendable {
    case overview, status, configuration, diagnostics, permissions, startup, federation, events, roadmap
}

enum NeoYSetupCommand: Equatable, Sendable {
    case help(topic: NeoYSetupTopic?)
    case status
    case configuration
    case diagnosticsEnable
    case diagnosticsDisable
    case diagnosticsSet(NeoYDiagnosticsSetting)
    case permissionsStatus
    case permissionOpen(NeoYPermissionKind)
    case startupList
    case startupAdd(name: String, executable: String, arguments: [String])
    case startupRemove(String)
    case startupEnable(name: String, enabled: Bool)
    case startupSetCWD(name: String, path: String?)
    case startupSetRestart(name: String, policy: NeoYRestartPolicy)
    case startupSetEnvironment(name: String, key: String, value: String?)
    case mcpList
    case mcpAdd(name: String, url: String)
    case mcpRemove(String)
    case mcpEnable(name: String, enabled: Bool)
    case eventsStatus
    case eventsSet(kind: NeoYImportantEventKind, enabled: Bool)
    case eventNotify(kind: NeoYImportantEventKind, title: String, body: String)
}

enum NeoYSetupError: LocalizedError {
    case unknownCommand(String)
    case unknownTopic(String)
    case unexpectedArgument(String)
    case missingArgument(String)
    case unmatchedQuote
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let value): "unknown command '\(value)'; run 'help'"
        case .unknownTopic(let value):
            "unknown topic '\(value)'; supported topics: \(NeoYSetupTopic.allCases.map(\.rawValue).joined(separator: ", "))"
        case .unexpectedArgument(let value): "unexpected argument '\(value)'"
        case .missingArgument(let value): "missing argument: \(value)"
        case .unmatchedQuote: "unmatched quote"
        case .invalidValue(let value): value
        }
    }
}

enum NeoYSetupParser {
    static func parse(_ raw: String?) throws -> NeoYSetupCommand {
        var tokens = try tokenize(raw ?? "")
        while tokens.first == "neoy.setup" || tokens.first == "setup" { tokens.removeFirst() }
        guard let command = tokens.first else { return .help(topic: nil) }

        switch command {
        case "help": return try help(tokens)
        case "status":
            try exact(tokens, count: 1)
            return .status
        case "config":
            guard tokens == ["config", "show"] else { throw NeoYSetupError.unknownCommand(tokens.joined(separator: " ")) }
            return .configuration
        case "diagnostics": return try diagnostics(tokens)
        case "permissions": return try permissions(tokens)
        case "startup": return try startup(tokens)
        case "mcp": return try mcp(tokens)
        case "events": return try events(tokens)
        default: throw NeoYSetupError.unknownCommand(command)
        }
    }

    private static func help(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count <= 2 else { throw NeoYSetupError.unexpectedArgument(tokens[2]) }
        guard tokens.count == 2 else { return .help(topic: nil) }
        guard let topic = NeoYSetupTopic(rawValue: tokens[1]) else { throw NeoYSetupError.unknownTopic(tokens[1]) }
        return .help(topic: topic)
    }

    private static func diagnostics(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { throw NeoYSetupError.missingArgument("diagnostics subcommand") }
        switch tokens[1] {
        case "enable":
            try exact(tokens, count: 2)
            return .diagnosticsEnable
        case "disable":
            try exact(tokens, count: 2)
            return .diagnosticsDisable
        case "set":
            guard tokens.count == 4 else { throw NeoYSetupError.missingArgument("diagnostics set <level|retention-days> <value>") }
            switch tokens[2] {
            case "level":
                guard let level = NeoYDiagnosticsLevel(rawValue: tokens[3]) else {
                    throw NeoYControlPlaneError.invalidDiagnosticsLevel(tokens[3])
                }
                return .diagnosticsSet(.level(level))
            case "retention-days":
                guard let days = Int(tokens[3]) else { throw NeoYControlPlaneError.invalidRetentionDays(0) }
                guard (1...365).contains(days) else { throw NeoYControlPlaneError.invalidRetentionDays(days) }
                return .diagnosticsSet(.retentionDays(days))
            default: throw NeoYControlPlaneError.invalidDiagnosticsProperty(tokens[2])
            }
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func permissions(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { return .permissionsStatus }
        switch tokens[1] {
        case "status":
            try exact(tokens, count: 2)
            return .permissionsStatus
        case "open":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("permissions open <kind>") }
            guard let kind = NeoYPermissionKind(rawValue: tokens[2]) else {
                throw NeoYSetupError.invalidValue("unknown permission '\(tokens[2])'")
            }
            return .permissionOpen(kind)
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func startup(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { throw NeoYSetupError.missingArgument("startup subcommand") }
        switch tokens[1] {
        case "list":
            try exact(tokens, count: 2)
            return .startupList
        case "add":
            guard tokens.count >= 4 else { throw NeoYSetupError.missingArgument("startup add <name> <absolute-executable> [args...]") }
            return .startupAdd(name: tokens[2], executable: tokens[3], arguments: Array(tokens.dropFirst(4)))
        case "remove":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("startup remove <name>") }
            return .startupRemove(tokens[2])
        case "enable", "disable":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("startup \(tokens[1]) <name>") }
            return .startupEnable(name: tokens[2], enabled: tokens[1] == "enable")
        case "set":
            guard tokens.count >= 4 else { throw NeoYSetupError.missingArgument("startup set <cwd|restart|env|unset-env> ...") }
            switch tokens[2] {
            case "cwd":
                guard tokens.count == 5 else { throw NeoYSetupError.missingArgument("startup set cwd <name> <absolute-path|none>") }
                return .startupSetCWD(name: tokens[3], path: tokens[4] == "none" ? nil : tokens[4])
            case "restart":
                guard tokens.count == 5, let policy = NeoYRestartPolicy(rawValue: tokens[4]) else {
                    throw NeoYSetupError.invalidValue("restart must be never, on-failure, or always")
                }
                return .startupSetRestart(name: tokens[3], policy: policy)
            case "env":
                guard tokens.count == 6 else { throw NeoYSetupError.missingArgument("startup set env <name> <KEY> <VALUE>") }
                return .startupSetEnvironment(name: tokens[3], key: tokens[4], value: tokens[5])
            case "unset-env":
                guard tokens.count == 5 else { throw NeoYSetupError.missingArgument("startup set unset-env <name> <KEY>") }
                return .startupSetEnvironment(name: tokens[3], key: tokens[4], value: nil)
            default: throw NeoYSetupError.unknownCommand(tokens.prefix(3).joined(separator: " "))
            }
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func mcp(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { throw NeoYSetupError.missingArgument("mcp subcommand") }
        switch tokens[1] {
        case "list":
            try exact(tokens, count: 2)
            return .mcpList
        case "add":
            guard tokens.count == 4 else { throw NeoYSetupError.missingArgument("mcp add <name> <http(s)-url>") }
            return .mcpAdd(name: tokens[2], url: tokens[3])
        case "remove":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("mcp remove <name>") }
            return .mcpRemove(tokens[2])
        case "enable", "disable":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("mcp \(tokens[1]) <name>") }
            return .mcpEnable(name: tokens[2], enabled: tokens[1] == "enable")
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func events(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { return .eventsStatus }
        switch tokens[1] {
        case "status":
            try exact(tokens, count: 2)
            return .eventsStatus
        case "enable", "disable":
            guard tokens.count == 3, let kind = NeoYImportantEventKind(rawValue: tokens[2]) else {
                throw NeoYSetupError.invalidValue("event kind must be blocked, failure, or completed")
            }
            return .eventsSet(kind: kind, enabled: tokens[1] == "enable")
        case "notify":
            guard tokens.count >= 5, let kind = NeoYImportantEventKind(rawValue: tokens[2]) else {
                throw NeoYSetupError.missingArgument("events notify <kind> <title> <body...>")
            }
            return .eventNotify(kind: kind, title: tokens[3], body: tokens.dropFirst(4).joined(separator: " "))
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func exact(_ tokens: [String], count: Int) throws {
        if tokens.count > count { throw NeoYSetupError.unexpectedArgument(tokens[count]) }
        if tokens.count < count { throw NeoYSetupError.missingArgument("argument") }
    }

    private static func tokenize(_ raw: String) throws -> [String] {
        var tokens: [String] = []
        var token = ""
        var quoted = false
        for character in raw {
            switch character {
            case "\"": quoted.toggle()
            case " ", "\t", "\n", "\r":
                if quoted { token.append(character) }
                else if !token.isEmpty { tokens.append(token); token = "" }
            default: token.append(character)
            }
        }
        if quoted { throw NeoYSetupError.unmatchedQuote }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }
}

enum NeoYRuntimeState: String, Codable, Sendable {
    case ready, degraded
}

struct NeoYRuntimeEndpoint: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let isRunning: Bool
    let error: String?
}

struct NeoYPhonePairingSelection: Codable, Equatable, Sendable {
    let isSelected: Bool
    let name: String?
    let kind: String?
    let url: String?

    static let unavailable = NeoYPhonePairingSelection(isSelected: false, name: nil, kind: nil, url: nil)
}

struct NeoYRuntimeStatus: Codable, Equatable, Sendable {
    let state: NeoYRuntimeState
    let version: String
    let bundleIdentifier: String
    let startupMode: String
    let mcp: NeoYRuntimeEndpoint
    let neoXPairing: NeoYPhonePairingSelection
    let handoff: NeoYRuntimeEndpoint
    let capabilities: [String]
    var controlPlane: NeoYControlPlaneHealth?
}

struct NeoYConfigurationSnapshot: Codable, Equatable, Sendable {
    let configuration: NeoYControlPlaneConfiguration
    let controlPlane: NeoYControlPlaneHealth
}

struct NeoYConfigurationMutationResult: Codable, Equatable, Sendable {
    let ok: Bool
    let operation: String
    let error: String?
    let configuration: NeoYControlPlaneConfiguration
    let controlPlane: NeoYControlPlaneHealth
}

actor NeoYSetupService {
    private let makeStatus: @Sendable () async -> NeoYRuntimeStatus
    private let controlPlane: NeoYControlPlaneService
    private let runtime: NeoYRuntimeControl?

    init(
        makeStatus: @escaping @Sendable () async -> NeoYRuntimeStatus,
        controlPlane: NeoYControlPlaneService = NeoYControlPlaneService(
            store: NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory)
        ),
        runtime: NeoYRuntimeControl? = nil
    ) {
        self.makeStatus = makeStatus
        self.controlPlane = controlPlane
        self.runtime = runtime
    }

    func currentConfiguration() async -> NeoYControlPlaneConfiguration {
        await controlPlane.currentConfiguration()
    }

    func execute(_ command: NeoYSetupCommand) async -> String {
        switch command {
        case .help(let topic): return Self.help(topic)
        case .status:
            var status = await makeStatus()
            status.controlPlane = await controlPlane.currentHealth()
            return Self.json(status)
        case .configuration:
            return Self.json(await snapshot())
        case .diagnosticsEnable:
            return await mutate("diagnostics.enable") { try await self.controlPlane.setDiagnosticsEnabled(true) }
        case .diagnosticsDisable:
            return await mutate("diagnostics.disable") { try await self.controlPlane.setDiagnosticsEnabled(false) }
        case .diagnosticsSet(let setting):
            return await mutate("diagnostics.set") { try await self.controlPlane.setDiagnostics(setting) }
        case .permissionsStatus:
            return Self.json(await runtime?.permissions() ?? [])
        case .permissionOpen(let kind):
            return Self.json(JSONValue.object(["opened": .bool(await runtime?.openPermission(kind) ?? false), "permission": .string(kind.rawValue)]))
        case .startupList:
            let configuration = await controlPlane.currentConfiguration()
            return Self.json(await runtime?.startupStatus(configuration) ?? [])
        case .startupAdd(let name, let executable, let arguments):
            return await mutateAndReconcile("startup.add") {
                try await self.controlPlane.upsertStartup(.init(name: name, executable: executable, arguments: arguments))
            }
        case .startupRemove(let name):
            return await mutateAndReconcile("startup.remove") { try await self.controlPlane.removeStartup(name) }
        case .startupEnable(let name, let enabled):
            return await mutateAndReconcile("startup.\(enabled ? "enable" : "disable")") {
                try await self.controlPlane.updateStartup(name) { $0.isEnabled = enabled }
            }
        case .startupSetCWD(let name, let path):
            return await mutateAndReconcile("startup.set.cwd") {
                try await self.controlPlane.updateStartup(name) { $0.workingDirectory = path }
            }
        case .startupSetRestart(let name, let policy):
            return await mutateAndReconcile("startup.set.restart") {
                try await self.controlPlane.updateStartup(name) { $0.restartPolicy = policy }
            }
        case .startupSetEnvironment(let name, let key, let value):
            return await mutateAndReconcile("startup.set.environment") {
                try await self.controlPlane.updateStartup(name) {
                    if let value { $0.environment[key] = value } else { $0.environment.removeValue(forKey: key) }
                }
            }
        case .mcpList:
            let configuration = await controlPlane.currentConfiguration()
            return Self.json(await runtime?.federationStatus(configuration) ?? [])
        case .mcpAdd(let name, let url):
            return await mutateAndReconcile("mcp.add") {
                try await self.controlPlane.upsertMCP(.init(name: name, url: url))
            }
        case .mcpRemove(let name):
            return await mutateAndReconcile("mcp.remove") { try await self.controlPlane.removeMCP(name) }
        case .mcpEnable(let name, let enabled):
            return await mutateAndReconcile("mcp.\(enabled ? "enable" : "disable")") {
                try await self.controlPlane.setMCPEnabled(name, enabled: enabled)
            }
        case .eventsStatus:
            return Self.json((await controlPlane.currentConfiguration()).events)
        case .eventsSet(let kind, let enabled):
            return await mutate("events.\(enabled ? "enable" : "disable")") {
                try await self.controlPlane.setEvent(kind, enabled: enabled)
            }
        case .eventNotify(let kind, let title, let body):
            do {
                guard let runtime else { throw NeoYRuntimeControlError.event("runtime event bridge is unavailable") }
                let config = await controlPlane.currentConfiguration()
                return try await runtime.notify(kind: kind, title: title, body: body, configuration: config)
            } catch {
                return Self.json(JSONValue.object(["delivered": .bool(false), "error": .string(error.localizedDescription)]))
            }
        }
    }

    private func snapshot() async -> NeoYConfigurationSnapshot {
        NeoYConfigurationSnapshot(
            configuration: await controlPlane.currentConfiguration(),
            controlPlane: await controlPlane.currentHealth())
    }

    private func mutate(
        _ operation: String,
        mutation: @Sendable () async throws -> NeoYControlPlaneConfiguration
    ) async -> String {
        do {
            let configuration = try await mutation()
            return Self.json(NeoYConfigurationMutationResult(
                ok: true, operation: operation, error: nil, configuration: configuration,
                controlPlane: await controlPlane.currentHealth()))
        } catch {
            return Self.json(NeoYConfigurationMutationResult(
                ok: false, operation: operation, error: error.localizedDescription,
                configuration: await controlPlane.currentConfiguration(),
                controlPlane: await controlPlane.currentHealth()))
        }
    }

    private func mutateAndReconcile(
        _ operation: String,
        mutation: @Sendable () async throws -> NeoYControlPlaneConfiguration
    ) async -> String {
        do {
            let configuration = try await mutation()
            await runtime?.reconcile(configuration)
            return Self.json(NeoYConfigurationMutationResult(
                ok: true, operation: operation, error: nil, configuration: configuration,
                controlPlane: await controlPlane.currentHealth()))
        } catch {
            return Self.json(NeoYConfigurationMutationResult(
                ok: false, operation: operation, error: error.localizedDescription,
                configuration: await controlPlane.currentConfiguration(),
                controlPlane: await controlPlane.currentHealth()))
        }
    }

    static func help(_ topic: NeoYSetupTopic?) -> String {
        switch topic {
        case .overview:
            "NeoY is Neo's signed menu-bar Mac runtime. One setup CLI configures native trust, supervised services, federated MCPs, diagnostics, and NeoX events."
        case .status:
            "'status' returns runtime, MCP, NeoX pairing/handoff, capability, and control-plane health."
        case .configuration:
            "'config show' returns versioned validated configuration without making storage paths part of the normal UX."
        case .diagnostics:
            "diagnostics enable|disable; diagnostics set level <info|warning|error>; diagnostics set retention-days <1...365>"
        case .permissions:
            "permissions status; permissions open <accessibility|screen-recording|camera|microphone|notifications|local-network>. Human approval remains required."
        case .startup:
            """
            startup list
            startup add <name> <absolute-executable> [args...]
            startup remove|enable|disable <name>
            startup set cwd <name> <absolute-path|none>
            startup set restart <name> <never|on-failure|always>
            startup set env <name> <KEY> <VALUE>
            startup set unset-env <name> <KEY>
            """
        case .federation:
            """
            mcp list
            mcp add <name> <http(s)-mcp-url>
            mcp remove|enable|disable <name>
            Enabled remote tools appear as mcp.<server>.<tool>. Use startup services to supervise local MCP server processes.
            """
        case .events:
            """
            events status
            events enable|disable <blocked|failure|completed>
            events notify <kind> "<title>" <body...>
            Only policy-enabled important events are forwarded to the paired NeoX runtime.
            """
        case .roadmap:
            "v2 core is implemented around typed persistence, native permission guidance, supervised startup services, HTTP MCP federation, and pairing-aware NeoX important-event delivery. Signed installed-app permission/login E2E still requires the actual installed identity and human TCC approvals."
        case nil:
            """
            NeoY setup CLI
              help [topic]
              status
              config show
              diagnostics ...
              permissions status|open ...
              startup list|add|remove|enable|disable|set ...
              mcp list|add|remove|enable|disable ...
              events status|enable|disable|notify ...

            Run 'help <topic>' for exact grammar. Runtime help is authoritative for the installed NeoY version.
            """
        }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{\"state\":\"degraded\",\"error\":\"encoding failed\"}" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum NeoYSetupTools {
    static func tools(service: NeoYSetupService) -> [ToolDefinition] {
        [ToolDefinition(
            name: "neoy.setup",
            description: "NeoY setup/control CLI. Run without command or run 'help' for authoritative runtime commands covering status, permissions, supervised startup services, MCP federation, diagnostics, and important NeoX events.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("CLI-like NeoY setup command; omit for help"),
                    ]),
                ]),
            ])
        ) { args in
            let raw: String?
            if case .object(let object) = args, case .string(let value)? = object["command"] { raw = value }
            else { raw = nil }
            do { return await service.execute(try NeoYSetupParser.parse(raw)) }
            catch { return "Error: \(error.localizedDescription)" }
        }]
    }
}
