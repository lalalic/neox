import Foundation

enum NeoYSetupTopic: String, CaseIterable, Sendable {
    case overview
    case status
    case roadmap
}

enum NeoYSetupCommand: Equatable, Sendable {
    case help(topic: NeoYSetupTopic?)
    case status
}

enum NeoYSetupError: LocalizedError {
    case unknownCommand(String)
    case unknownTopic(String)
    case unexpectedArgument(String)
    case unmatchedQuote

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
        default:
            throw NeoYSetupError.unknownCommand(command)
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
}

actor NeoYSetupService {
    private let makeStatus: @Sendable () async -> NeoYRuntimeStatus

    init(makeStatus: @escaping @Sendable () async -> NeoYRuntimeStatus) {
        self.makeStatus = makeStatus
    }

    func execute(_ command: NeoYSetupCommand) async -> String {
        switch command {
        case .help(let topic):
            return Self.help(topic)
        case .status:
            return Self.statusJSON(await makeStatus())
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
        case .roadmap:
            return """
            Current milestone: typed setup foundation. Deferred milestones: \
            permissions, startup supervision, MCP federation, diagnostics, \
            notification bridging, and mutation commands. Deferred commands are \
            intentionally absent until their services are implemented.
            """
        case nil:
            return """
            NeoY setup CLI

            Commands:
              help                     Show this command reference.
              help <topic>             Show overview, status, or roadmap.
              status                   Return runtime status as compact JSON.

            This milestone is read-only. Help is authoritative for commands \
            implemented by the installed runtime version.
            """
        }
    }

    private static func statusJSON(_ status: NeoYRuntimeStatus) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        guard let data = try? encoder.encode(status) else {
            return "{\"state\":\"degraded\",\"error\":\"status encoding failed\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum NeoYSetupTools {
    static func tools(service: NeoYSetupService) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "neoy.setup",
                description: "NeoY setup/control CLI. Read-only commands: help [overview|status|roadmap], status.",
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
