import Foundation

enum NeoYBundledRuntime {
    static let macBridgeProviderName = "macbridge"

    static func coreMCPServers(
        resourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> [NeoYMCPServerConfiguration] {
        guard let resourceURL else { return [] }
        let bridge = resourceURL
            .appendingPathComponent("neoy-runtime", isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("mac-developer-bridge", isDirectory: true)
            .appendingPathComponent("bridge.mjs")
        guard fileManager.isReadableFile(atPath: bridge.path) else { return [] }
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        guard let node = nodeCandidates.first(where: fileManager.isExecutableFile(atPath:)) else { return [] }

        var components = URLComponents()
        components.scheme = "stdio"
        components.path = node
        components.queryItems = [URLQueryItem(name: "arg", value: bridge.path)]
        guard let url = components.string else { return [] }
        return [.init(name: macBridgeProviderName, url: url, isEnabled: true)]
    }

    static func exposedToolName(provider: String, tool: String) -> String? {
        if provider == macBridgeProviderName {
            if tool.hasPrefix("chrome_") || tool.hasPrefix("chatgpt_") { return nil }
            return tool
        }
        if provider == "events" { return "events.\(tool)" }
        return "mcp.\(provider).\(tool)"
    }

    static func resolvedMCPServers(
        userServers: [NeoYMCPServerConfiguration],
        resourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> [NeoYMCPServerConfiguration] {
        let external = userServers.filter { $0.name != macBridgeProviderName }
        return coreMCPServers(resourceURL: resourceURL, fileManager: fileManager) + external
    }
}
