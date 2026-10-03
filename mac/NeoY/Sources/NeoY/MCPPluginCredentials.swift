import Foundation

enum NeoYMCPPluginCredentials {
    private static let clientIDFile = NeoYPaths.supportDirectory.appendingPathComponent("mcp-client-id")

    struct Credentials: Equatable {
        let clientID: String
        let token: String
    }

    static func current() -> Credentials {
        let clientID = loadClientID() ?? createClientID()
        return Credentials(clientID: clientID, token: NeoYCoreAuth.token())
    }

    private static func loadClientID() -> String? {
        guard let value = try? String(contentsOf: clientIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func createClientID() -> String {
        let clientID = randomID()
        do {
            try FileManager.default.createDirectory(
                at: NeoYPaths.supportDirectory,
                withIntermediateDirectories: true
            )
            try (clientID + "\n").write(to: clientIDFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: clientIDFile.path
            )
        } catch {
            return clientID
        }
        return clientID
    }

    private static func randomID() -> String {
        "neoy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
