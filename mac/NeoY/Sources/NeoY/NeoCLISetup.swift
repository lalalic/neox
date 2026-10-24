import Foundation

/// NeoY manages installation; lalalic/neo remains the CLI implementation owner.
enum NeoCLISetup {
    static var skillsDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills", isDirectory: true) }
    static let requiredGlobalSkills = ["events-bus", "daemon-service-manage", "webhelm"]
    static func globalSkills() -> [String] { requiredGlobalSkills }

    static let optionalSkillSources = [
        "wechat-bro": "lalalic/wechat-bro",
        "markcut": "lalalic/markcut",
        "agents-relay": "lalalic/agents-relay",
    ]

    static func removeOptionalSkill(_ name: String) throws {
        guard optionalSkillSources[name] != nil,
              !requiredGlobalSkills.contains(name) else {
            throw NSError(domain: "NeoCLISetup", code: 4, userInfo: [NSLocalizedDescriptionKey: "not an optional Neo Skill"])
        }
        _ = try runSkills(["remove", name, "-g", "-y"])
    }

    static func allInstalledGlobalSkills() -> Set<String> {
        let inventory = (try? runSkills(["list", "-g", "--json"])) ?? ""
        guard let data = inventory.data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return Set(records.compactMap { $0["name"] as? String })
    }

    static func projectNames() -> [String] {
        guard let executable = cliPath() else { return [] }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["project", "list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let projects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return projects.compactMap { $0["xchat_project"] as? String }.sorted()
        } catch { return [] }
    }

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
    static let npmCLI = "@lalalic/neo@1.0.2"
    static let npmPackage = "@lalalic/neo"
    static let expectedVersion = "1.0.2"

    static func managedToolkitInstalled() -> Bool {
        guard let npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let installed = try? installedNPMPackages(using: npm),
              installed[npmPackage] != nil else { return false }
        if let cli = cliPath(), isDevelopmentLink(cli) { return false }
        return true
    }

    static func uninstallManagedToolkit() throws -> String {
        guard managedToolkitInstalled() else {
            return "No managed Neo Project Toolkit installation. Developer links are preserved."
        }
        guard let npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "NeoCLISetup", code: 5, userInfo: [NSLocalizedDescriptionKey: "npm unavailable"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["uninstall", "--global", npmPackage, "--no-audit", "--no-fund"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoCLISetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return "Neo Project Toolkit removed; required global Skills retained."
    }

    static func packageDecision(installed: [String: String], executableExists: Bool) -> String {
        if let legacy = installed["neo"] {
            return "migration_required: legacy neo@\(legacy) owns the command; remove or migrate it explicitly before installing \(npmPackage)"
        }
        if let current = installed[npmPackage] {
            return current == expectedVersion && executableExists
                ? "ready"
                : "upgrade_required: \(npmPackage) \(current) != \(expectedVersion)"
        }
        return executableExists
            ? "ownership_unknown: an existing neo command is not owned by \(npmPackage); preserve it"
            : "install"
    }
    static func installedNPMPackages(using npm: String) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["list", "--global", "--depth=0", "--json"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dependencies = root["dependencies"] as? [String: [String: Any]] else { return [:] }
        return dependencies.compactMapValues { $0["version"] as? String }
    }
    /// CLI is an independently published npm release, never a build-machine checkout.
    static func installIfMissing() throws -> String {
        guard let npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "CLI needs setup: npm unavailable"
        }
        let existing = cliPath()
        if let path = existing, isDevelopmentLink(path) {
            return "Developer CLI retained: \(path.path)"
        }
        let decision = packageDecision(installed: try installedNPMPackages(using: npm), executableExists: existing != nil)
        if decision == "ready" { return "CLI already installed: \(npmCLI)" }
        if decision != "install" { return "CLI needs setup: \(decision)" }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: npm)
        task.arguments = ["install", "--global", npmCLI, "--ignore-scripts", "--no-audit", "--no-fund"]
        task.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0, cliPath() != nil else {
            return "CLI npm install failed (exit \(task.terminationStatus)): \(String(decoding: data, as: UTF8.self).suffix(300))"
        }
        return "CLI installed from npm \(npmCLI)"
    }
    /// Install only NeoY dependencies. Existing user-installed skills are never replaced.
    /// webhelm is supplied by the browser-workspace skill repository, independently of lalalic/neo.
    static func setupMissingGlobalSkills() throws -> String {
        let missing = Set(requiredGlobalSkills).subtracting(installedGlobalSkills())
        if missing.contains("events-bus") || missing.contains("daemon-service-manage") {
            for skill in ["events-bus", "daemon-service-manage"] where missing.contains(skill) {
                _ = try runSkills(["add", "lalalic/neo", "-g", "-y", "-s", skill])
            }
        }
        if missing.contains("webhelm") {
            _ = try runSkills(["add", "lalalic/browser-workspace", "-g", "-y", "-s", "webhelm"])
        }
        let installed = installedGlobalSkills()
        let remaining = requiredGlobalSkills.filter { !installed.contains($0) }
        guard remaining.isEmpty else { throw NSError(domain: "NeoCLISetup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Global Skills missing after install: \(remaining.joined(separator: ", "))"]) }
        return "Global dependencies present: \(installed.joined(separator: ", "))"
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
        return "CLI: \(location) | Neo Global Skills: \(installed.count)/\(requiredGlobalSkills.count)"
    }
}
