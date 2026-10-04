import Foundation

enum NeoYTunnelMode: String, Codable, CaseIterable, Identifiable {
    case off, quick, named
    var id: String { rawValue }
}

struct NeoYDeploymentSettings: Codable, Equatable {
    static let defaultPort: UInt16 = 6767
    var mcpPort: UInt16 = Self.defaultPort
    var tunnelMode: NeoYTunnelMode = .off
    var tunnelName: String = ""
    var publicHostname: String = ""
    var remoteTools: Set<String>? = nil
    var remoteFeatures: Set<String>? = nil // legacy; migrated to remoteTools on load
    var remoteProviders: Set<String>? = nil

    var enabledRemoteTools: Set<String> { remoteTools ?? [] }
    var enabledRemoteProviders: Set<String> { remoteProviders ?? [] }

    var localMCPURL: String { "http://127.0.0.1:\(mcpPort)/mcp" }

    var publicMCPURL: String? {
        guard tunnelMode != .off else { return nil }
        if tunnelMode == .named, !publicHostname.isEmpty {
            return "https://\(publicHostname)/mcp"
        }
        return NeoYDeploymentSettingsStore.quickTunnelURL().map { "\($0)/mcp" }
    }

    func validated() throws -> NeoYDeploymentSettings {
        if tunnelMode == .named {
            if !publicHostname.isEmpty {
                guard publicHostname.contains("."), !publicHostname.contains("://"), !publicHostname.contains("/") else {
                    throw NSError(domain: "NeoY", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "Public hostname must look like neoy.example.com"])
                }
            }
        }
        return self
    }
}

enum NeoYDeploymentSettingsStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NeoY", isDirectory: true)
    static let file = directory.appendingPathComponent("deployment.json")
    static let publicURLFile = directory.appendingPathComponent("public-url")

    static func load() -> NeoYDeploymentSettings {
        guard let data = try? Data(contentsOf: file),
              var value = try? JSONDecoder().decode(NeoYDeploymentSettings.self, from: data)
        else { return NeoYDeploymentSettings() }

        // 9224 was NeoY's pre-v2.2 default. There was no explicit-port marker
        // in that schema, so preserve every non-legacy value and migrate 9224.
        var migrated = false
        if value.mcpPort == 9224 {
            value.mcpPort = NeoYDeploymentSettings.defaultPort
            migrated = true
        }
        // Remote access is explicit. Migrate the old feature buckets to exact
        // public tool names so the UI and enforcement use the same contract.
        if value.remoteTools == nil {
            if let legacy = value.remoteFeatures {
                value.remoteTools = NeoYRemoteToolCatalog.migrateLegacyFeatures(legacy)
            } else if value.tunnelMode != .off {
                let config = (try? NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory)
                    .loadOrCreate().document.configuration) ?? NeoYControlPlaneConfiguration()
                value.remoteTools = Set(NeoYRemoteToolCatalog.availableToolNames(configuration: config))
            } else {
                value.remoteTools = []
            }
            migrated = true
        }
        if value.remoteFeatures != nil {
            value.remoteFeatures = nil
            migrated = true
        }
        if value.remoteProviders == nil {
            value.remoteProviders = []
            migrated = true
        }
        if migrated { try? save(value) }
        return value
    }

    static func save(_ settings: NeoYDeploymentSettings) throws {
        let value = try settings.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func quickTunnelURL() -> String? {
        guard let value = try? String(contentsOf: publicURLFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("https://") else { return nil }
        return value
    }
}
