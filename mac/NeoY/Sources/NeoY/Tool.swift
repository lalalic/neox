import Foundation

/// JSON value type for tool parameters and arguments.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }
}

/// A tool handler receives parsed arguments and returns a result string.
public typealias ToolHandler = @Sendable (JSONValue) async throws -> String

/// Defines a tool that can be called via MCP.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String?
    /// JSON Schema for parameters.
    public let parameters: JSONValue?
    public let handler: ToolHandler

    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue? = nil,
        handler: @escaping ToolHandler
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.handler = handler
    }
}


/// Builds one compact CLI-style MCP facade over a richer internal command set.
/// The public schema stays small (`command` + `args`); exact subcommand schemas
/// remain discoverable through `help`, while existing handlers remain the
/// source of truth for execution semantics and argument validation.
public enum CommandTool {
    public static func facade(
        name: String,
        description: String,
        commands: [ToolDefinition],
        commandName: @escaping @Sendable (String) -> String
    ) -> ToolDefinition {
        let commandMap = Dictionary(uniqueKeysWithValues: commands.map { (commandName($0.name), $0) })
        return ToolDefinition(
            name: name,
            description: description + " Use command='help' to list subcommands or inspect one subcommand's exact args schema.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("Subcommand name, or 'help'."),
                    ]),
                    "args": .object([
                        "type": .string("object"),
                        "description": .string("Arguments for the selected subcommand. Use help for the exact schema."),
                    ]),
                ]),
                "required": .array([.string("command")]),
                "additionalProperties": .bool(false),
            ])
        ) { input in
            guard case .object(let object) = input,
                  case .string(let requested)? = object["command"] else {
                throw CommandToolError.message("command is required")
            }
            let args = object["args"] ?? .object([:])
            if requested == "help" {
                let named: String?
                if case .object(let helpArgs) = args, case .string(let value)? = helpArgs["command"] {
                    named = value
                } else {
                    named = nil
                }
                if let named {
                    guard let command = commandMap[named] else {
                        throw CommandToolError.message("Unknown \(name) command '\(named)'")
                    }
                    return json([
                        "command": .string(named),
                        "description": .string(command.description ?? ""),
                        "schema": command.parameters ?? .object(["type": .string("object")]),
                    ])
                }
                let rows: [JSONValue] = commandMap.keys.sorted().compactMap { key in
                    guard let command = commandMap[key] else { return nil }
                    return .object([
                        "command": .string(key),
                        "description": .string(command.description ?? ""),
                    ])
                }
                return json(["commands": .array(rows)])
            }
            guard let command = commandMap[requested] else {
                throw CommandToolError.message("Unknown \(name) command '\(requested)'")
            }
            return try await command.handler(args)
        }
    }

    public static func stripPrefix(_ prefix: String) -> @Sendable (String) -> String {
        { value in value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value }
    }

    private static func json(_ object: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

private enum CommandToolError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}
