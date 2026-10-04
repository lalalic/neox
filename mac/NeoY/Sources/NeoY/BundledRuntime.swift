import Foundation

enum NeoYBundledRuntime {
    static let coreProviderName = "core"
    static let legacyMacBridgeProviderName = "macbridge"
    static var coreEnvironment: [String: String] {
        [
            "NEO_CORE_FULL_ACCESS_ACK": "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS",
            "NEOY_VERSION": NeoYCoreRuntime.version,
        ]
    }

    static func isBundledProviderName(_ name: String) -> Bool {
        name == coreProviderName || name == legacyMacBridgeProviderName
    }

    static var repoRuntimeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent("neox", isDirectory: true)
            .appendingPathComponent("mac", isDirectory: true)
            .appendingPathComponent("NeoY", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    static func coreMCPServers(
        runtimeURL: URL = repoRuntimeURL,
        fileManager: FileManager = .default
    ) -> [NeoYMCPServerConfiguration] {
        let tools = runtimeURL
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("core", isDirectory: true)
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("index.mjs")
        guard fileManager.isReadableFile(atPath: tools.path) else { return [] }

        let nodeCandidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".volta/bin/node").path,
            "/usr/bin/node",
        ]
        guard let node = nodeCandidates.first(where: fileManager.isExecutableFile(atPath:)) else { return [] }

        var components = URLComponents()
        components.scheme = "stdio"
        components.path = node
        components.queryItems = [URLQueryItem(name: "arg", value: tools.path)]
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
        runtimeURL: URL = repoRuntimeURL,
        fileManager: FileManager = .default
    ) -> [NeoYMCPServerConfiguration] {
        let external = userServers.filter { !isBundledProviderName($0.name) }
        return coreMCPServers(runtimeURL: runtimeURL, fileManager: fileManager) + external
    }
}
