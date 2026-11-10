import Foundation

/// One user-controlled Neo Projects root. Harness installation is app-managed.
struct NeoWorkspaceConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 1
    static var defaultNeoRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Workspace", isDirectory: true)
            .standardizedFileURL
    }
    static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/neo/workspace.json")
    }

    let schemaVersion: Int
    let neoRoot: String

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
        // Fail closed rather than silently accepting a different or obsolete root schema.
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == Set(["schemaVersion", "neoRoot"]) else { throw Error.invalidConfiguration }
        let config = try JSONDecoder().decode(Self.self, from: data)
        guard config.schemaVersion == currentSchemaVersion,
              try validate(config.neoRoot) == config.neoRoot else { throw Error.invalidConfiguration }
        return config
    }

    static func save(neoRoot: String, to file: URL = configurationURL) throws -> Self {
        let validRoot = try validate(neoRoot)
        let config = Self(schemaVersion: currentSchemaVersion, neoRoot: validRoot)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.sorted.encode(config)
        try data.write(to: file, options: .atomic)
        let readBack = try load(from: file)
        guard readBack == config else { throw Error.readbackMismatch }
        return readBack
    }

    /// One-time schema conversion on app upgrade, not a legacy project resolver.
    /// Preserve the effective previously selected Projects Root instead of
    /// silently resetting users to the default directory.
    private static func migrateSavedRootIfNeeded(at file: URL) throws {
        let data = try Data(contentsOf: file)
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidConfiguration
        }
        if Set(source.keys) == Set(["schemaVersion", "neoRoot"]) { return }
        let keys = Set(source.keys)
        guard (source["schemaVersion"] as? Int) == currentSchemaVersion,
              (keys == Set(["schemaVersion", "workspaceRoot"]) ||
               keys == Set(["schemaVersion", "workspaceRoot", "projectsRoot"])),
              let oldWorkspace = source["workspaceRoot"] as? String else {
            throw Error.invalidConfiguration
        }
        if keys.contains("projectsRoot") && !(source["projectsRoot"] is String) {
            throw Error.invalidConfiguration
        }
        // Old workspaceRoot was the *parent* of the effective Neo Projects
        // directory, not the directory itself. Keep its /neo child on upgrade.
        // An explicitly saved projectsRoot already denoted the Project root.
        let selected: String
        if let previousProjectsRoot = source["projectsRoot"] as? String {
            selected = previousProjectsRoot
        } else {
            let parent = try validate(oldWorkspace)
            let previousNeoRoot = URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent("neo", isDirectory: true)
            try FileManager.default.createDirectory(at: previousNeoRoot, withIntermediateDirectories: true)
            selected = previousNeoRoot.path
        }
        _ = try save(neoRoot: selected, to: file)
    }

    /// Preserve an existing Neo Root; fresh users get ~/Workspace.
    @discardableResult
    static func prepareIfNeeded(fileManager: FileManager = .default,
                                at file: URL = configurationURL) throws -> Self {
        if !fileManager.fileExists(atPath: file.path) {
            try fileManager.createDirectory(at: defaultNeoRoot, withIntermediateDirectories: true)
            _ = try save(neoRoot: defaultNeoRoot.path, to: file)
        } else {
            try migrateSavedRootIfNeeded(at: file)
        }
        let saved = try load(from: file)
        try fileManager.createDirectory(atPath: saved.neoRoot, withIntermediateDirectories: true)
        return saved
    }

    enum Error: LocalizedError {
        case notAbsolute, notDirectory, invalidConfiguration, readbackMismatch
        var errorDescription: String? {
            switch self {
            case .notAbsolute: "Choose an absolute directory path."
            case .notDirectory: "The Neo Root must be an existing directory."
            case .invalidConfiguration: "The saved Neo Root configuration is invalid."
            case .readbackMismatch: "The saved Neo Root did not match the applied value."
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
