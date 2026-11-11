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

    // Copy Core into the signed app bundle at build time. Never use a developer checkout
    // as an implicit production fallback. Missing Core remains an unavailable provider.
    static var packagedRuntimeURL: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    // Rust is an opt-in, independently installed Core child. Keep the existing
    // managed Node version as the immediate rollback path.
    static var rustBinaryURL: URL {
        NeoYPaths.supportDirectory.appendingPathComponent("core/rust/neoy-core-rust")
    }
    static var coreProviderSelectionURL: URL {
        NeoYPaths.supportDirectory.appendingPathComponent("core/rust/provider")
    }

    static func preferredBackend(marker: URL = coreProviderSelectionURL) -> String {
        (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "rust"
            ? "rust" : "node"
    }

    static func selectBackend(
        _ backend: String,
        rustBinary: URL = rustBinaryURL,
        marker: URL = coreProviderSelectionURL,
        fileManager: FileManager = .default
    ) throws {
        guard backend == "node" || backend == "rust" else {
            throw NSError(domain: "NeoYCore", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "core provider must be node or rust"])
        }
        if backend == "node" {
            if fileManager.fileExists(atPath: marker.path) { try fileManager.removeItem(at: marker) }
            return
        }
        guard fileManager.isExecutableFile(atPath: rustBinary.path) else {
            throw NSError(domain: "NeoYCore", code: 31,
                          userInfo: [NSLocalizedDescriptionKey: "Rust Core executable has not been installed"])
        }
        try fileManager.createDirectory(at: marker.deletingLastPathComponent(),
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try Data("rust\n".utf8).write(to: marker, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    static func coreMCPServers(
        runtimeURL: URL = NeoYManagedCoreRuntime.selected(),
        fileManager: FileManager = .default,
        rustBinary: URL = rustBinaryURL,
        marker: URL = coreProviderSelectionURL
    ) -> [NeoYMCPServerConfiguration] {
        if preferredBackend(marker: marker) == "rust", fileManager.isExecutableFile(atPath: rustBinary.path) {
            var components = URLComponents()
            components.scheme = "stdio"
            components.path = rustBinary.path
            guard let url = components.string else { return [] }
            return [.init(name: coreProviderName, url: url, isEnabled: true)]
        }
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
        runtimeURL: URL = NeoYManagedCoreRuntime.selected(),
        fileManager: FileManager = .default,
        rustBinary: URL = rustBinaryURL,
        marker: URL = coreProviderSelectionURL
    ) -> [NeoYMCPServerConfiguration] {
        let external = userServers.filter { !isBundledProviderName($0.name) }
        return coreMCPServers(runtimeURL: runtimeURL, fileManager: fileManager,
                              rustBinary: rustBinary, marker: marker) + external
    }
}
