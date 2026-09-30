import Foundation

enum NeoYSetupTopic: String, CaseIterable, Sendable {
    case overview
    case status
    case roadmap
    case configuration
    case diagnostics
}

enum NeoYSetupCommand: Equatable, Sendable {
    case help(topic: NeoYSetupTopic?)
    case status
    case configuration
    case diagnosticsEnable
    case diagnosticsDisable
    case diagnosticsSet(NeoYDiagnosticsSetting)
}

enum NeoYSetupError: LocalizedError {
    case unknownCommand(String)
    case unknownTopic(String)
    case unexpectedArgument(String)
    case unmatchedQuote
    case invalidDiagnosticsSubcommand(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let value):
            return "unknown command '\(value)'; run 'help'"
        case .unknownTopic(let value):
            return "unknown topic '\(value)'; supported topics: \(NeoYSetupTopic.allCases.map(\.rawValue).joined(separator: ", "))"
        case .unexpectedArgument(let value):
            return "unexpected argument '\(value)'"
        case .unmatchedQuote:
            return "unmatched quote"
        case .invalidDiagnosticsSubcommand(let value):
            return "unknown diagnostics subcommand '\(value)'; supported subcommands: enable, disable, set"
        }
    }
}

enum NeoYSetupParser {
    static func parse(_ raw: String?) throws -> NeoYSetupCommand {
        var tokens = try tokenize(raw ?? "")

        if tokens.first == "neoy.setup" || tokens.first == "setup" {
            tokens.removeFirst()
            while tokens.first == "neoy.setup" || tokens.first == "setup" {
                tokens.removeFirst()
            }
        }

        guard let command = tokens.first else {
            return .help(topic: nil)
        }

        switch command {
        case "help":
            guard tokens.count <= 2 else {
                throw NeoYSetupError.unexpectedArgument(tokens[2])
            }
            guard let topic = tokens.last else {
                return .help(topic: nil)
            }
            guard let value = NeoYSetupTopic(rawValue: topic) else {
                throw NeoYSetupError.unknownTopic(topic)
            }
            return .help(topic: value)
        case "status":
            guard tokens.count == 1 else {
                throw NeoYSetupError.unexpectedArgument(tokens[1])
            }
            return .status
        case "config":
            guard tokens.count == 2, tokens[1] == "show" else {
                throw NeoYSetupError.unknownCommand(tokens.joined(separator: " "))
            }
            return .configuration
        case "diagnostics":
            guard tokens.count >= 2 else {
                throw NeoYSetupError.unexpectedArgument("diagnostics")
            }
            switch tokens[1] {
            case "enable":
                guard tokens.count == 2 else {
                    throw NeoYSetupError.unexpectedArgument(tokens[2])
                }
                return .diagnosticsEnable
            case "disable":
                guard tokens.count == 2 else {
                    throw NeoYSetupError.unexpectedArgument(tokens[2])
                }
                return .diagnosticsDisable
            case "set":
                guard tokens.count == 4 else {
                    throw NeoYSetupError.unexpectedArgument(tokens[min(tokens.count, 4)])
                }
                return .diagnosticsSet(try Self.diagnosticsSetting(tokens[2], value: tokens[3]))
            default:
                throw NeoYSetupError.invalidDiagnosticsSubcommand(tokens[1])
            }
        default:
            throw NeoYSetupError.unknownCommand(command)
        }
    }

    private static func diagnosticsSetting(_ property: String, value: String) throws -> NeoYDiagnosticsSetting {
        switch property {
        case "level":
            guard let level = NeoYDiagnosticsLevel(rawValue: value) else {
                throw NeoYControlPlaneError.invalidDiagnosticsLevel(value)
            }
            return .level(level)
        case "retention-days":
            guard let days = Int(value) else {
                throw NeoYControlPlaneError.invalidRetentionDays(0)
            }
            guard (1...365).contains(days) else {
                throw NeoYControlPlaneError.invalidRetentionDays(days)
            }
            return .retentionDays(days)
        default:
            throw NeoYControlPlaneError.invalidDiagnosticsProperty(property)
        }
    }

    private static func tokenize(_ raw: String) throws -> [String] {
        var tokens: [String] = []
        var token = ""
        var isQuoted = false

        for character in raw {
            switch character {
            case "\"":
                isQuoted.toggle()
            case " ", "\t", "\n", "\r":
                if isQuoted {
                    token.append(character)
                } else if !token.isEmpty {
                    tokens.append(token)
                    token = ""
                }
            default:
                token.append(character)
            }
        }

        if isQuoted {
            throw NeoYSetupError.unmatchedQuote
        }
        if !token.isEmpty {
            tokens.append(token)
        }
        return tokens
    }
}

enum NeoYRuntimeState: String, Codable, Sendable {
    case ready
    case degraded
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

    static let unavailable = NeoYPhonePairingSelection(
        isSelected: false,
        name: nil,
        kind: nil,
        url: nil
    )
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

actor NeoYSetupService {
    private let makeStatus: @Sendable () async -> NeoYRuntimeStatus
    private let controlPlane: NeoYControlPlaneService

    init(
        makeStatus: @escaping @Sendable () async -> NeoYRuntimeStatus,
        controlPlane: NeoYControlPlaneService = NeoYControlPlaneService(
            store: NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory)
        )
    ) {
        self.makeStatus = makeStatus
        self.controlPlane = controlPlane
    }

    func execute(_ command: NeoYSetupCommand) async -> String {
        switch command {
        case .help(let topic):
            return Self.help(topic)
        case .status:
            var status = await makeStatus()
            status.controlPlane = await controlPlane.currentHealth()
            return Self.json(status)
        case .configuration:
            return Self.json(
                NeoYConfigurationSnapshot(
                    configuration: await controlPlane.currentConfiguration(),
                    controlPlane: await controlPlane.currentHealth()
                )
            )
        case .diagnosticsEnable:
            return await mutationResult(operation: "diagnostics.enable") {
                try await controlPlane.setDiagnosticsEnabled(true)
            }
        case .diagnosticsDisable:
            return await mutationResult(operation: "diagnostics.disable") {
                try await controlPlane.setDiagnosticsEnabled(false)
            }
        case .diagnosticsSet(let setting):
            return await mutationResult(operation: "diagnostics.set") {
                try await controlPlane.setDiagnostics(setting)
            }
        }
    }

    static func help(_ topic: NeoYSetupTopic?) -> String {
        switch topic {
        case .overview:
            return """
            NeoY is the signed, menu-bar macOS runtime for Neo. Native services \
            own high-trust Mac capabilities and preserve existing NeoX pairing. \
            Configuration and diagnostics enter through this stable setup command.
            """
        case .status:
            return """
            'status' returns compact JSON with overall state, app identity, MCP \
            endpoint state, NeoX pairing selection, phone handoff state, and \
            enabled native capabilities.
            """
        case .configuration:
            return """
            'config show' returns the validated control-plane configuration \
            and its persistence health.
            """
        case .diagnostics:
            return """
            Diagnostics commands persist validated local settings:
              diagnostics enable
              diagnostics disable
              diagnostics set level <info|warning|error>
              diagnostics set retention-days <1...365>
            """
        case .roadmap:
            return """
            Current milestone: versioned control-plane persistence and \
            diagnostics settings. Deferred milestones: permissions, startup \
            supervision, MCP federation, and NeoX event bridging. Deferred \
            commands are intentionally absent until their services exist.
            """
        case nil:
            return """
            NeoY setup CLI

            Commands:
              help                     Show this command reference.
              help <topic>             Show overview, status, roadmap, config, or diagnostics.
              status                   Return runtime status as compact JSON.
              config show              Return durable configuration and health.
              diagnostics enable       Enable local diagnostics.
              diagnostics disable      Disable local diagnostics.
              diagnostics set level    Set info, warning, or error.
              diagnostics set retention-days
                                       Set retention from 1 through 365 days.

            Help is authoritative for commands \
            implemented by the installed runtime version.
            """
        }
    }

    private func mutationResult(
        operation: String,
        _ mutation: @Sendable () async throws -> NeoYControlPlaneConfiguration
    ) async -> String {
        do {
            let configuration = try await mutation()
            return Self.json(
                NeoYConfigurationMutationResult(
                    ok: true,
                    operation: operation,
                    error: nil,
                    configuration: configuration,
                    controlPlane: await controlPlane.currentHealth()
                )
            )
        } catch {
            return Self.json(
                NeoYConfigurationMutationResult(
                    ok: false,
                    operation: operation,
                    error: error.localizedDescription,
                    configuration: await controlPlane.currentConfiguration(),
                    controlPlane: await controlPlane.currentHealth()
                )
            )
        }
    }

    private static func json(_ value: some Encodable & Sendable) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(value) else {
            return "{\"state\":\"degraded\",\"error\":\"configuration encoding failed\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
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

enum NeoYSetupTools {
    static func tools(service: NeoYSetupService) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "neoy.setup",
                description: """
                    NeoY setup/control CLI. Commands: help [overview|status|roadmap|configuration|diagnostics], \
                    status, config show, diagnostics enable|disable, diagnostics set level|retention-days.
                    """,
                parameters: schema()
            ) { args in
                let raw: String?
                if case .object(let object) = args, case .string(let value)? = object["command"] {
                    raw = value
                } else {
                    raw = nil
                }

                do {
                    return await service.execute(try NeoYSetupParser.parse(raw))
                } catch {
                    return "Error: \(error.localizedDescription)"
                }
            },
        ]
    }

    private static func schema() -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Command text; omit for setup help"),
                ]),
            ]),
        ])
    }
}
