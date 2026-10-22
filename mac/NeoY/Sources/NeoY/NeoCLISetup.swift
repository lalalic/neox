import Foundation

/// NeoY manages installation; lalalic/neo remains the CLI implementation owner.
enum NeoCLISetup {
    static var skillsDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills", isDirectory: true) }
    static func globalSkills() -> [String] {
        let paths = (try? FileManager.default.contentsOfDirectory(at: skillsDirectory, includingPropertiesForKeys: nil)) ?? []
        return paths.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }.map(\.lastPathComponent).sorted()
    }
    static func cliPath() -> URL? {
        ["/opt/homebrew/bin/neo", "/usr/local/bin/neo"].first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
    static func isDevelopmentLink(_ path: URL) -> Bool {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path) else { return false }
        return URL(fileURLWithPath: dest, relativeTo: path.deletingLastPathComponent()).standardizedFileURL.path.contains("/Workspace/neo/")
    }
    static var bundledPackage: URL? {
        Bundle.main.url(forResource: "neo-cli", withExtension: "tgz", subdirectory: "Packages")
    }

    static func installIfMissing(packageTarball: URL? = bundledPackage) throws -> String {
        if let path = cliPath() { return isDevelopmentLink(path) ? "Developer CLI retained: \(path.path)" : "CLI already installed: \(path.path)" }
        guard let packageTarball, FileManager.default.fileExists(atPath: packageTarball.path) else {
            return "CLI needs setup: no verified Neo package artifact configured"
        }
        guard let npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "CLI needs setup: npm unavailable"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: npm)
        task.arguments = ["install", "--global", packageTarball.path, "--ignore-scripts", "--no-audit", "--no-fund"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0, cliPath() != nil else { return "CLI installation failed (exit \(task.terminationStatus))" }
        return "CLI installed from verified artifact"
    }
    /// Install only previously missing skills. Never replace user-owned directories or links.
    /// Skill payloads are staged with the verified CLI, not downloaded ad hoc.
    static func installMissingGlobalSkills(from packageRoot: URL) throws -> [String] {
        let source = packageRoot.appendingPathComponent("skills", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        var installed: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard FileManager.default.fileExists(atPath: entry.appendingPathComponent("SKILL.md").path) else { continue }
            let dest = skillsDirectory.appendingPathComponent(entry.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dest.path) &&
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: dest.path)) == nil else { continue }
            try FileManager.default.copyItem(at: entry, to: dest)
            installed.append(entry.lastPathComponent)
        }
        return installed
    }

    static func installedPackageRoot() -> URL? {
        guard let cli = cliPath() else { return nil }
        let actual = cli.resolvingSymlinksInPath()
        guard actual.lastPathComponent == "neo.mjs", actual.deletingLastPathComponent().lastPathComponent == ".bin" else { return nil }
        let root = actual.deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("skills").path) else { return nil }
        return root
    }

    static func setup() -> String {
        do {
            let cli = try installIfMissing()
            guard let root = installedPackageRoot() else { return cli + "; skill source not available" }
            let added = try installMissingGlobalSkills(from: root)
            return cli + "; installed \(added.count) missing Global Skills"
        } catch {
            return "Neo CLI / Global Skills setup failed: \(error.localizedDescription)"
        }
    }

    static func report() -> String {
        let location = cliPath().map { isDevelopmentLink($0) ? "developer link" : $0.path } ?? "missing"
        return "CLI: \(location) | Global Skills: \(globalSkills().count) (~/.agents/skills/)"
    }
}
