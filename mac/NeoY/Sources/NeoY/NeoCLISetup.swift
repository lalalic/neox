import Foundation

/// NeoY manages installation; lalalic/neo remains the CLI implementation owner.
enum NeoCLISetup {
    static var skillsDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills", isDirectory: true) }
    static let requiredGlobalSkills = ["events-bus", "daemon-service-manage", "webhelm"]
    static func globalSkills() -> [String] { requiredGlobalSkills }

    static func installedGlobalSkills() -> [String] {
        let inventory = (try? runSkills(["list", "-g", "--json"])) ?? ""
        guard let data = inventory.data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let names = Set(records.compactMap { $0["name"] as? String })
        return requiredGlobalSkills.filter { names.contains($0) }
    }

    static func runSkills(_ arguments: [String]) throws -> String {
        guard let npx = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "NeoCLISetup", code: 1, userInfo: [NSLocalizedDescriptionKey: "npx unavailable"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["--yes", "skills"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoCLISetup", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "npx skills failed: \(String(decoding: data, as: UTF8.self).prefix(400))"])
        }
        return String(decoding: data, as: UTF8.self)
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
    /// Install only NeoY dependencies. Existing user-installed skills are never replaced.
    /// webhelm is supplied by the browser-workspace skill repository, independently of lalalic/neo.
    static func setupMissingGlobalSkills() throws -> String {
        let missing = Set(requiredGlobalSkills).subtracting(installedGlobalSkills())
        if missing.contains("events-bus") || missing.contains("daemon-service-manage") {
            let selected = ["events-bus", "daemon-service-manage"].filter { missing.contains($0) }
            _ = try runSkills(["add", "lalalic/neo", "-g", "-y", "-s"] + selected)
        }
        if missing.contains("webhelm") {
            // Repository source must be configured/validated before any installation is attempted.
            return "webhelm missing: install from its verified browser-workspace source"
        }
        return "Global dependencies present: \(installedGlobalSkills().joined(separator: ", "))"
    }

    static func setup() -> String {
        do {
            let cli = try installIfMissing()
            let skills = try setupMissingGlobalSkills()
            return cli + "; " + skills
        } catch {
            return "Neo CLI / Global Skills setup failed: \(error.localizedDescription)"
        }
    }

    static func report() -> String {
        let location = cliPath().map { isDevelopmentLink($0) ? "developer link" : $0.path } ?? "missing"
        let installed = Set(installedGlobalSkills())
        return "CLI: \(location) | NeoY Global Skills: \(installed.count)/\(requiredGlobalSkills.count)"
    }
}
