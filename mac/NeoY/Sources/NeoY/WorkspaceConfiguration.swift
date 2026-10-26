import Foundation

struct NeoWorkspaceConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 1
    static var defaultWorkspaceRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
    }
    static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neo/workspace.json")
    }

    let schemaVersion: Int
    let workspaceRoot: String

    var neoRoot: String {
        URL(fileURLWithPath: workspaceRoot, isDirectory: true)
            .appendingPathComponent("neo", isDirectory: true).path
    }

    static func validate(_ input: String, fileManager: FileManager = .default) throws -> String {
        let expanded = (input as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Error.notAbsolute }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Error.notDirectory
        }
        return url.path
    }

    static func load(from file: URL = configurationURL) throws -> Self {
        let data = try Data(contentsOf: file)
        let config = try JSONDecoder().decode(Self.self, from: data)
        guard config.schemaVersion == currentSchemaVersion,
              try validate(config.workspaceRoot) == config.workspaceRoot else { throw Error.invalidConfiguration }
        return config
    }

    static func save(workspaceRoot: String, to file: URL = configurationURL) throws -> Self {
        let validRoot = try validate(workspaceRoot)
        let config = Self(schemaVersion: currentSchemaVersion, workspaceRoot: validRoot)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.sorted.encode(config)
        try data.write(to: file, options: .atomic)
        let readBack = try load(from: file)
        guard readBack == config else { throw Error.readbackMismatch }
        return readBack
    }

    enum Error: LocalizedError {
        case notAbsolute, notDirectory, invalidConfiguration, readbackMismatch
        var errorDescription: String? {
            switch self {
            case .notAbsolute: "Choose an absolute directory path."
            case .notDirectory: "The Workspace Root must be an existing directory."
            case .invalidConfiguration: "The saved Workspace Root configuration is invalid."
            case .readbackMismatch: "The saved Workspace Root did not match the applied value."
            }
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
