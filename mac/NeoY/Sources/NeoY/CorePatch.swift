import Foundation

struct NeoYPatchResult: Codable, Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let checkOnly: Bool
    let reverse: Bool
    let threeWay: Bool
}

struct NeoYPatchService: Sendable {
    func apply(arguments: JSONValue) throws -> String {
        guard case .object(let object) = arguments else {
            throw NeoYCoreError.invalidCommand("apply_patch arguments must be an object")
        }
        guard case .string(let patch)? = object["patch"], !patch.isEmpty else {
            throw NeoYCoreError.missingArgument("patch")
        }

        let cwd: String
        if case .string(let value)? = object["cwd"] { cwd = expandHome(value) }
        else { cwd = FileManager.default.homeDirectoryForCurrentUser.path }

        let checkOnly = bool(object["check_only"])
        let reverse = bool(object["reverse"])
        let threeWay = bool(object["three_way"])

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NeoYCoreError.notFound("working directory not found: \(cwd)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var args = ["apply", "--recount", "--whitespace=nowarn"]
        if checkOnly { args.append("--check") }
        if reverse { args.append("--reverse") }
        if threeWay { args.append("--3way") }
        args.append("-")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() }
        catch { throw NeoYCoreError.operationFailed("git apply could not start: \(error.localizedDescription)") }

        stdin.fileHandleForWriting.write(Data(patch.utf8))
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let result = NeoYPatchResult(
            exitCode: process.terminationStatus,
            stdout: out,
            stderr: err,
            checkOnly: checkOnly,
            reverse: reverse,
            threeWay: threeWay
        )
        return NeoYCoreJSON.encode(result)
    }

    private func bool(_ value: JSONValue?) -> Bool {
        if case .bool(let result)? = value { return result }
        return false
    }

    private func expandHome(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}

enum NeoYPatchTools {
    static func tools(service: NeoYPatchService = .init()) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "apply_patch",
                description: "Apply or check a unified diff using git apply in the specified working directory. This does not invoke a model.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "patch": .object([
                            "type": .string("string"),
                            "minLength": .int(1),
                            "description": .string("Unified diff to pass to git apply")
                        ]),
                        "cwd": .object([
                            "type": .string("string"),
                            "description": .string("Working directory; defaults to the current macOS user's home directory")
                        ]),
                        "check_only": .object([
                            "type": .string("boolean"),
                            "default": .bool(false)
                        ]),
                        "reverse": .object([
                            "type": .string("boolean"),
                            "default": .bool(false)
                        ]),
                        "three_way": .object([
                            "type": .string("boolean"),
                            "default": .bool(false)
                        ])
                    ]),
                    "required": .array([.string("patch")]),
                    "additionalProperties": .bool(false)
                ])
            ) { arguments in
                try service.apply(arguments: arguments)
            }
        ]
    }
}
