import Foundation

enum NeoYTunnelMode: String, Codable, CaseIterable, Identifiable {
    case off, quick, named
    var id: String { rawValue }
}

struct NeoYDeploymentSettings: Codable, Equatable {
    var mcpPort: UInt16 = 9224
    var tunnelMode: NeoYTunnelMode = .off
    var tunnelName: String = "neoy"
    var publicHostname: String = ""
    var chatGPTPluginID: String = ""

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
            guard !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(domain: "NeoY", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Named tunnel requires a tunnel name"])
            }
            guard publicHostname.contains("."), !publicHostname.contains("://"), !publicHostname.contains("/") else {
                throw NSError(domain: "NeoY", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Public hostname must look like neoy.example.com"])
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
              let value = try? JSONDecoder().decode(NeoYDeploymentSettings.self, from: data)
        else { return NeoYDeploymentSettings() }
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
