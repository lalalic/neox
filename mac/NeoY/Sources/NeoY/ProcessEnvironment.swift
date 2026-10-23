import Foundation

enum NeoYProcessEnvironment {
    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
        // An inherited acknowledgement must not silently elevate a new Core child.
        // Full Core access requires its own explicit, revocable unlock file.
        environment.removeValue(forKey: "NEO_CORE_FULL_ACCESS_ACK")
        for key in environment.keys where key.hasPrefix("MAC_DEV_BRIDGE_") {
            environment.removeValue(forKey: key)
        }
        var entries = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let additions = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectory.appendingPathComponent(".local/bin").path,
        ]
        for path in additions where !entries.contains(path) { entries.append(path) }
        environment["PATH"] = entries.joined(separator: ":")
        return environment
    }
}
