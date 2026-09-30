import Foundation

enum NeoYCommandLine {
    struct Parsed {
        let tokens: [String]
        let remainder: String?
    }

    static func parse(_ raw: String) throws -> Parsed {
        if let range = raw.range(of: " -- ") {
            let head = String(raw[..<range.lowerBound])
            let tail = String(raw[range.upperBound...])
            return Parsed(tokens: try tokenize(head), remainder: tail)
        }
        return Parsed(tokens: try tokenize(raw), remainder: nil)
    }

    static func tokenize(_ raw: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func flush() {
            if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }

        for character in raw {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
        }

        if escaping { current.append("\\") }
        guard quote == nil else { throw NeoYCoreError.invalidCommand("unmatched quote") }
        flush()
        return result
    }
}

enum NeoYCoreError: LocalizedError {
    case invalidCommand(String)
    case missingArgument(String)
    case notFound(String)
    case operationFailed(String)
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand(let value): value
        case .missingArgument(let value): "missing argument: \(value)"
        case .notFound(let value): value
        case .operationFailed(let value): value
        case .unauthorized(let value): value
        }
    }
}

enum NeoYCoreJSON {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{\"error\":\"encoding_failed\"}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func command(from arguments: JSONValue) throws -> String {
        guard case .object(let object) = arguments,
              case .string(let command)? = object["command"] else {
            throw NeoYCoreError.missingArgument("command")
        }
        return command
    }

    static func string(_ value: String) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string(value)
                ])
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false)
        ])
    }
}
