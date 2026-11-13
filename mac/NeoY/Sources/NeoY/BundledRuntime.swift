import Foundation

enum NeoYBundledRuntime {
    static let coreProviderName = "core"
    static let legacyMacBridgeProviderName = "macbridge"
    static var coreEnvironment: [String: String] {
        [
            "NEO_CORE_DATA_DIR": NeoYPaths.supportDirectory.appendingPathComponent("core", isDirectory: true).path,
            "NEO_CORE_LOG_DIR": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("NeoY", isDirectory: true)
                .appendingPathComponent("Core", isDirectory: true).path,
            "NEOY_VERSION": NeoYCoreRuntime.version,
            "NEO_CORE_FULL_ACCESS_ACK": "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
        ]
    }

    static func isBundledProviderName(_ name: String) -> Bool {
        name == coreProviderName || name == legacyMacBridgeProviderName
    }

    // Only the independently installed Rust child (or the signed app seed)
    // may provide Core. Never use a Node runtime as an implicit fallback.
    static func coreMCPServers(
        binary: URL? = NeoYManagedRustCoreRuntime.selected(),
        fileManager: FileManager = .default
    ) -> [NeoYMCPServerConfiguration] {
        guard let binary, fileManager.isExecutableFile(atPath: binary.path) else { return [] }
        var components = URLComponents()
        components.scheme = "stdio"
        components.path = binary.path
        guard let url = components.string else { return [] }
        return [.init(name: coreProviderName, url: url, isEnabled: true)]
    }

    static func exposedToolName(provider: String, tool: String) -> String? {
        if provider == coreProviderName {
            return tool
        }
        if provider == legacyMacBridgeProviderName {
            return nil
        }
        if provider == "events" { return "events" }
        return "mcp.\(provider)"
    }

    static func resolvedMCPServers(
        userServers: [NeoYMCPServerConfiguration],
        binary: URL? = NeoYManagedRustCoreRuntime.selected(),
        fileManager: FileManager = .default
    ) -> [NeoYMCPServerConfiguration] {
        let external = userServers.filter { !isBundledProviderName($0.name) }
        return coreMCPServers(binary: binary, fileManager: fileManager) + external
    }
}
