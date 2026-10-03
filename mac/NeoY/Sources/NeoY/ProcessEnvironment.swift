import Foundation

enum NeoYProcessEnvironment {
    static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        var environment = base
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
