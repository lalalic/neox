import Foundation

/// NeoY manages installation; lalalic/neo remains the CLI implementation owner.
enum NeoCLISetup {
    static var skillsDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents/skills", isDirectory: true) }
    static let requiredGlobalSkills = ["events-bus", "daemon-service-manage", "webhelm", "agents-relay", "markcut"]
    static func globalSkills() -> [String] { requiredGlobalSkills }

    // Required/built-in Global Skills never get a user-facing Features toggle.
    static let optionalSkillSources = [
        "wechat-bro": "lalalic/wechat-bro",
    ]

    // Trusted sources only. A remote MCP provider cannot install an arbitrary
    // repository by declaring a dependency.
    static let requiredSkillSources = [
        "events-bus": "lalalic/neo",
        "daemon-service-manage": "lalalic/neo",
        "webhelm": "lalalic/browser-workspace",
        "agents-relay": "lalalic/agents-relay",
        "markcut": "lalalic/markcut",
    ]
    static var managedSkillSources: [String: String] {
        requiredSkillSources.merging(optionalSkillSources) { existing, _ in existing }
    }
    static let skillPrerequisites: [String: Set<String>] = [
        "events-bus": ["daemon-service-manage"],
        "webhelm": ["daemon-service-manage"],
        "wechat-bro": ["daemon-service-manage"],
    ]

    /// Tool-to-Skill prerequisites, independent of the MCP provider lifecycle.
    static let toolSkillRequirements: [String: Set<String>] = [
        "markcut_preview": ["markcut"],
        "markcut.preview": ["markcut"],
        "neo_markcut_preview": ["markcut"],
        "chatgpt": ["webhelm"],
        "webhelm": ["webhelm"],
        "browser-workspace": ["webhelm"],
    ]

    /// Supports known aliases, browser tool namespaces, and trusted skill names
    /// advertised in tools/list _meta.neo.requires.skills.
    static func requiredSkills(forTool tool: String, advertised: Set<String> = []) -> Set<String> {
        var required = toolSkillRequirements[tool] ?? []
        if tool.hasPrefix("webhelm.") || tool.hasPrefix("browser-workspace.") {
            required.insert("webhelm")
        }
        if tool.hasPrefix("markcut.") || tool.hasPrefix("markcut_") {
            required.insert("markcut")
        }
        required.formUnion(advertised)
        var pending = Array(required)
        while let skill = pending.popLast() {
            for prerequisite in skillPrerequisites[skill] ?? [] where !required.contains(prerequisite) {
                required.insert(prerequisite)
                pending.append(prerequisite)
            }
        }
        return required
    }

    static func advertisedSkills(from tool: [String: Any]) -> Set<String> {
        let meta = tool["_meta"] as? [String: Any] ?? [:]
        let neo = meta["neo"] as? [String: Any] ?? [:]
        let requires = neo["requires"] as? [String: Any] ?? [:]
        return Set(requires["skills"] as? [String] ?? [])
    }

    static func missingSkills(forTool tool: String, installed: Set<String>) -> Set<String> {
        requiredSkills(forTool: tool).subtracting(installed)
    }

    /// Fast, side-effect-free dependency guard for actual MCP execution.
    static func missingSkillsOnDisk(forTool tool: String, directory: URL? = nil,
                                   advertised: Set<String> = []) -> Set<String> {
        let root = directory ?? skillsDirectory
        return Set(requiredSkills(forTool: tool, advertised: advertised).filter { name in
            // The installed WebHelm Skill may belong to any agent and live anywhere.
            // Its self-setup owns the one global CLI, which is the consumer contract.
            if name == "webhelm", directory == nil,
               FileManager.default.isExecutableFile(atPath: globalWebhelmCLI.path) {
                return false
            }
            if FileManager.default.fileExists(atPath: root
                .appendingPathComponent(name).appendingPathComponent("SKILL.md").path) {
                return false
            }
            return true
        })
    }

    /// Install and read back every trusted transitive Skill requirement.
    /// The caller must run this off the main actor (npx may access the network).
    static func ensureSkills(_ names: Set<String>) throws -> Set<String> {
        let available = managedSkillSources
        let expanded = names.reduce(into: Set<String>()) { result, name in
            result.formUnion(requiredSkills(forTool: "", advertised: [name]))
        }
        guard !expanded.isEmpty else { return [] }
        var installed = try installedGlobalSkillNames()
        // Do not install a duplicate Skill if another agent already provided
        // its global webhelm command from an arbitrary Skill directory.
        if FileManager.default.isExecutableFile(atPath: globalWebhelmCLI.path) {
            installed.insert("webhelm")
        }
        let unapproved = expanded.subtracting(installed).subtracting(available.keys)
        guard unapproved.isEmpty else {
            throw NSError(domain: "NeoSkillDependency", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Missing Skill has no approved installation source: \(unapproved.sorted().joined(separator: ", "))"])
        }
        for name in expanded.sorted() where !installed.contains(name) {
            guard let source = available[name] else { continue }
            _ = try runSkills(["add", source, "-g", "-y", "-s", name])
            installed = try installedGlobalSkillNames()
            guard installed.contains(name) else {
                throw NSError(domain: "NeoSkillDependency", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Skill \(name) not found after installation."])
            }
        }
        return expanded
    }

    private static let dependencySetupLock = NSLock()

    static func ensureToolSkills(_ requirements: Set<String>) throws -> String {
        try dependencySetupLock.withLock {
            let installed = try ensureSkills(requirements)
            return try setupInstalledSkills(installed)
        }
    }

    /// A Skill with no runtime setup contract is ready after installation.
    /// WebHelm owns its browser daemon; initialize it through its public CLI.
    /// Authentication/Chrome Store approvals remain explicitly interactive.
    static func setupInstalledSkills(_ names: Set<String>) throws -> String {
        guard names.contains("webhelm") else {
            return names.isEmpty ? "No Tool Skill dependencies" :
                "Installed required Skills: \(names.sorted().joined(separator: ", "))"
        }
        try setupWebhelm()
        return "Installed required Skills: \(names.sorted().joined(separator: ", ")); WebHelm healthy"
    }

    private static var globalWebhelmCLI: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/webhelm")
    }

    private static func runWebhelm(_ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: globalWebhelmCLI.path) else {
            throw NSError(domain: "NeoSkillDependency", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Global webhelm executable is unavailable. Load the webhelm Skill and follow its CLI setup instructions."])
        }
        let process = Process()
        process.executableURL = globalWebhelmCLI
        process.arguments = arguments
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        process.environment = ProcessInfo.processInfo.environment
            .merging(["PATH": "\(path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoSkillDependency", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "WebHelm \(arguments.first ?? "command") failed: \(String(decoding: data, as: UTF8.self).prefix(250))"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func webhelmIsHealthy(_ status: String) -> Bool {
        guard let data = status.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let daemon = root["daemon"] as? [String: Any],
              daemon["running"] as? Bool == true,
              root["managed_chrome"] as? [String: Any] != nil else {
            return false
        }
        return true
    }

    static func setupWebhelm() throws {
        if let state = try? runWebhelm(["status"]), webhelmIsHealthy(state) { return }
        // First-use bootstrap. Always release the temporary leased session.
        let response = try runWebhelm(["session", "start"])
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = object["session_id"] as? String,
              !session.isEmpty else {
            throw NSError(domain: "NeoSkillDependency", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "WebHelm session start returned no session ID"])
        }
        defer { _ = try? runWebhelm(["session", "stop", session]) }
        guard webhelmIsHealthy(try runWebhelm(["status"])) else {
            throw NSError(domain: "NeoSkillDependency", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "WebHelm daemon did not become healthy"])
        }
    }

    static let toolkitPreferenceKey = "NeoProjectsToolkitEnabled"
    static let optionalSkillsPreferenceKey = "NeoOptionalSkillsEnabled"
    static let projectSelectionPreferenceKey = "NeoEnabledProjects"
    static let autoUpdateToolkitKey = "NeoAutoUpdateToolkit"
    private static let lastToolkitUpdateKey = "NeoLastToolkitUpdate"
    static let autoUpdateSkillsKey = "NeoAutoUpdateSkills"
    static let autoUpdateProjectsKey = "NeoAutoUpdateProjects"
    private static let lastSkillUpdateKey = "NeoLastSkillUpdate"
    private static let lastProjectUpdateKey = "NeoLastProjectUpdate"

    /// A project can be enabled even without a service lifecycle. This selection
    /// controls Neo's project management and automatic update operations.
    static func enabledProjects(discovered: [String], defaults: UserDefaults = .standard) -> Set<String> {
        let names = Set(discovered)
        guard let selected = defaults.stringArray(forKey: projectSelectionPreferenceKey) else { return names }
        return Set(selected).intersection(names)
    }

    static func setProjectEnabled(_ name: String, enabled: Bool, discovered: [String],
                                  defaults: UserDefaults = .standard) {
        guard discovered.contains(name) else { return }
        var selected = enabledProjects(discovered: discovered, defaults: defaults)
        if enabled { selected.insert(name) } else { selected.remove(name) }
        // Preserve preferences for names temporarily missing from discovery.
        let missing = Set(defaults.stringArray(forKey: projectSelectionPreferenceKey) ?? [])
            .subtracting(discovered)
        defaults.set(Array(selected.union(missing)).sorted(), forKey: projectSelectionPreferenceKey)
    }

    static func updateDue(last: Date?, now: Date = Date()) -> Bool {
        last.map { now.timeIntervalSince($0) >= 86_400 } ?? true
    }

    /// On existing installations preserve the observed CLI choice. New users
    /// must explicitly enable the optional Projects Toolkit.
    static func wantsProjectsToolkit(defaults: UserDefaults = .standard) -> Bool {
        if let value = defaults.object(forKey: toolkitPreferenceKey) as? Bool { return value }
        return cliPath() != nil
    }

    static func desiredOptionalSkills(defaults: UserDefaults = .standard) -> Set<String> {
        guard let names = defaults.stringArray(forKey: optionalSkillsPreferenceKey) else { return [] }
        return Set(names).intersection(optionalSkillSources.keys)
    }

    static func setOptionalSkillDesired(_ name: String, enabled: Bool, defaults: UserDefaults = .standard) {
        guard optionalSkillSources[name] != nil else { return }
        var names = desiredOptionalSkills(defaults: defaults)
        if enabled { names.insert(name) } else { names.remove(name) }
        defaults.set(names.sorted(), forKey: optionalSkillsPreferenceKey)
    }

    /// First upgrade from inventory-only checkboxes: inherit installed options
    /// once, so an external deletion can later be repaired without changing intent.
    static func migrateOptionalSkillPreferencesIfNeeded(installed: Set<String>,
                                                         defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: optionalSkillsPreferenceKey) == nil else { return }
        let selected = installed.intersection(optionalSkillSources.keys)
        defaults.set(selected.sorted(), forKey: optionalSkillsPreferenceKey)
    }

    /// Reinstall only user-selected optional Skills that have gone missing.
    static func reconcileDesiredOptionalSkills(defaults: UserDefaults = .standard) throws {
        let desired = desiredOptionalSkills(defaults: defaults)
        guard !desired.isEmpty else { return }
        _ = try ensureToolSkills(desired)
    }

    static func removeOptionalSkill(_ name: String) throws {
        guard optionalSkillSources[name] != nil,
              !requiredGlobalSkills.contains(name) else {
            throw NSError(domain: "NeoCLISetup", code: 4, userInfo: [NSLocalizedDescriptionKey: "not an optional Neo Skill"])
        }
        _ = try runSkills(["remove", name, "-g", "-y"])
    }

    static func updateOptionalSkill(_ name: String) throws {
        guard optionalSkillSources[name] != nil else {
            throw NSError(domain: "NeoCLISetup", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown optional Neo Skill"])
        }
        try updateManagedSkill(name)
    }

    static func autoUpdateEligible(name: String, installedSource: String?) -> Bool {
        guard let expected = managedSkillSources[name] else { return false }
        return expected == installedSource
    }

    static func updateManagedSkill(_ name: String, automatic: Bool = false) throws {
        guard managedSkillSources[name] != nil else {
            throw NSError(domain: "NeoCLISetup", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Unmanaged Skill update denied: \(name)"])
        }
        if automatic {
            let raw = try runSkills(["list", "-g", "--json"])
            guard let data = raw.data(using: .utf8),
                  let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let record = records.first(where: { ($0["name"] as? String) == name }),
                  autoUpdateEligible(name: name, installedSource: record["source"] as? String) else {
                throw NSError(domain: "NeoCLISetup", code: 7,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Skill \(name) source is unknown or locally managed; automatic updates skipped"])
            }
        }
        _ = try runSkills(["update", name, "-g", "-y"])
        let installed = try installedGlobalSkillNames()
        guard installed.contains(name) else {
            throw NSError(domain: "NeoCLISetup", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Skill disappeared after update: \(name)"])
        }
        if name == "webhelm" { try setupWebhelm() }
    }

    static func setupOptionalSkill(_ name: String) throws {
        guard optionalSkillSources[name] != nil else {
            throw NSError(domain: "NeoCLISetup", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown optional Neo Skill"])
        }
        let skill = skillsDirectory.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        try NeoYAgentSetupLauncher.open(bootstrap: skill, project: "skill/\(name)")
    }

    /// Opt-in daily updates; package/skill ownership stays with their existing CLIs.
    /// A failed update is logged and retried on the next daily check.
    static func autoUpdateIfDue(defaults: UserDefaults = .standard, now: Date = Date()) {
        if defaults.bool(forKey: autoUpdateSkillsKey),
           updateDue(last: defaults.object(forKey: lastSkillUpdateKey) as? Date, now: now) {
            defaults.set(now, forKey: lastSkillUpdateKey)
            let managed = Set(requiredGlobalSkills).union(desiredOptionalSkills(defaults: defaults))
            for name in managed.sorted() {
                do { try updateManagedSkill(name, automatic: true) }
                catch { NSLog("Neo Skill %@ auto-update skipped: %@", name, error.localizedDescription) }
            }
        }
        if defaults.bool(forKey: autoUpdateToolkitKey),
           updateDue(last: defaults.object(forKey: lastToolkitUpdateKey) as? Date, now: now) {
            defaults.set(now, forKey: lastToolkitUpdateKey)
            do { _ = try updateManagedToolkit() }
            catch { NSLog("Neo Project Toolkit auto-update skipped: %@", error.localizedDescription) }
        }
        if defaults.bool(forKey: autoUpdateProjectsKey),
           updateDue(last: defaults.object(forKey: lastProjectUpdateKey) as? Date, now: now) {
            defaults.set(now, forKey: lastProjectUpdateKey)
            var updatedRoots = Set<String>()
            let names = projectNames()
            for name in enabledProjects(discovered: names, defaults: defaults).sorted() {
                guard let info = try? projectInfo(name),
                      let gitRoot = info["git_root"] as? String,
                      updatedRoots.insert(gitRoot).inserted else { continue }
                do { _ = try updateProject(name) }
                catch { NSLog("Neo Project %@ auto-update skipped: %@", name, error.localizedDescription) }
            }
        }
    }

    static func allInstalledGlobalSkills() -> Set<String> {
        (try? installedGlobalSkillNames()) ?? []
    }

    /// Unlike the display inventory, startup reconciliation must distinguish
    /// an empty installation from an unavailable or invalid inventory.
    static func installedGlobalSkillNames() throws -> Set<String> {
        let inventory = try runSkills(["list", "-g", "--json"])
        guard let data = inventory.data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "NeoCLISetup", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid global Skills inventory"])
        }
        return Set(records.compactMap { $0["name"] as? String })
    }

    static func projectNames() -> [String] {
        guard let executable = cliPath() else { return [] }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["project", "list"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let projects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return neoProjectNames(from: projects)
        } catch { return [] }
    }

    static func projectInfo(_ name: String) throws -> [String: Any] {
        guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              let cli = cliPath() else {
            throw NSError(domain: "NeoProject", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid project"])
        }
        let resolver = Process()
        resolver.executableURL = cli
        resolver.arguments = ["project", "resolve", "neo/\(name)"]
        resolver.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let output = Pipe()
        resolver.standardOutput = output
        resolver.standardError = Pipe()
        try resolver.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        resolver.waitUntilExit()
        guard resolver.terminationStatus == 0,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["xchat_project"] as? String == "neo/\(name)",
              json["local_path"] is String else {
            throw NSError(domain: "NeoProject", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Project resolution failed"])
        }
        return json
    }

    static func projectRoot(_ name: String) throws -> URL {
        guard let root = try projectInfo(name)["local_path"] as? String else {
            throw NSError(domain: "NeoProject", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Project root missing"])
        }
        return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    }

    static func projectSetupBootstrap(_ name: String) -> URL? {
        guard let info = try? projectInfo(name),
              let setup = info["setup"] as? [String: Any],
              let path = setup["bootstrap"] as? String else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func projectSetupAgent(_ name: String) throws -> String {
        guard projectSetupBootstrap(name) != nil, let cli = cliPath() else {
            throw NSError(domain: "NeoProject", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Project has no setup agent"])
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["project", "setup-agent", "neo/\(name)"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let response = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoProject", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: response])
        }
        return response
    }

    /// Explicit, conservative Git update. A project can share its checkout with
    /// other Neo projects, so never reset, stash, or discard local work.
    static func updateProject(_ name: String) throws -> String {
        let root = try projectRoot(name)
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "NeoProject", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: result])
            }
            return result
        }
        guard try git(["status", "--porcelain"]).isEmpty else {
            throw NSError(domain: "NeoProject", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Project has local changes; update skipped."])
        }
        return try git(["pull", "--ff-only"])
    }

    /// Project-owned lifecycle scripts are the authority; NeoY does not manage PM2.
    static func projectLifecycle(_ name: String, command: String) throws -> String {
        let allowed = Set(["setup", "start", "stop", "restart", "status", "health", "uninstall"])
        guard allowed.contains(command) else {
            throw NSError(domain: "NeoProject", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid command"])
        }
        let root = try projectRoot(name)
        let script = root.appendingPathComponent("neo-project")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw NSError(domain: "NeoProject", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Project has no lifecycle entrypoint"])
        }
        let process = Process()
        process.executableURL = script
        process.arguments = [command]
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoProject", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(result.prefix(400))])
        }
        return result
    }

    static func projectLifecycleStatus(_ name: String) -> String? {
        guard let result = try? projectLifecycle(name, command: "status"),
              let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["status"] as? String
    }

    /// The CLI discovers every Workspace project and nested README directory.
    /// Show first-level Neo products, not nested runs or infrastructure skills.
    static func neoProjectNames(from records: [[String: Any]]) -> [String] {
        let names = records.compactMap { $0["xchat_project"] as? String }
        return Array(Set(names.filter { name in
            let parts = name.split(separator: "/")
            return parts.count == 2 && parts[0] == "neo" && parts[1] != "skills"
        }.map { String($0.dropFirst("neo/".count)) })).sorted()
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
    static let latestNpmCLI = "@lalalic/neo@latest"

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
            return executableExists &&
                (current == expectedVersion ||
                 current.compare(expectedVersion, options: .numeric) == .orderedDescending)
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
    static func installIfMissing(update: Bool = false) throws -> String {
        guard let npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return "CLI needs setup: npm unavailable"
        }
        let existing = cliPath()
        if let path = existing, isDevelopmentLink(path) {
            return "Developer CLI retained: \(path.path)"
        }
        let decision = packageDecision(installed: try installedNPMPackages(using: npm), executableExists: existing != nil)
        if decision == "ready" && !update { return "CLI already installed: \(npmCLI)" }
        if update && !managedToolkitInstalled() {
            return "Neo CLI update skipped: only managed npm installations may be updated."
        }
        // Only the known managed npm package may be updated without user action.
        // Never replace unknown commands, legacy packages, or developer links.
        if decision != "ready" && decision != "install" && !decision.hasPrefix("upgrade_required:") {
            return "CLI needs setup: \(decision)"
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: npm)
        task.arguments = ["install", "--global", update ? latestNpmCLI : npmCLI, "--ignore-scripts", "--no-audit", "--no-fund"]
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
        let version = try installedNPMPackages(using: npm)[npmPackage] ?? "unknown"
        return "CLI installed from npm \(npmPackage)@\(version)"
    }
    static func updateManagedToolkit() throws -> String {
        try installIfMissing(update: true)
    }
    /// Required Skill dependencies are installed and initialized at launch.
    /// Only approved sources are eligible for automatic installation.
    static func setupMissingGlobalSkills() throws -> String {
        try ensureToolSkills(Set(requiredGlobalSkills))
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


/// A user-owned Chrome conversation performs interactive project setup.
enum NeoYAgentSetupLauncher {
    static func prompt(bootstrap: URL, project: String) -> String {
        """
        Set up \(project) using @neo on my Mac. First read and follow this absolute bootstrap file:
        \(bootstrap.path)
        Run setup interactively, confirm permissions or credentials with me when needed, and verify the first real result. Do not claim success without evidence.
        """
    }

    static func url(bootstrap: URL, project: String) throws -> URL {
        guard bootstrap.isFileURL, bootstrap.path.hasPrefix("/"),
              FileManager.default.isReadableFile(atPath: bootstrap.path) else {
            throw NSError(domain: "NeoAgentSetup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bootstrap must be a readable local file"])
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chatgpt.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "prompt", value: prompt(bootstrap: bootstrap, project: project))]
        guard let url = components.url else {
            throw NSError(domain: "NeoAgentSetup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not construct ChatGPT setup URL"])
        }
        return url
    }

    static func open(bootstrap: URL, project: String) throws {
        let target = try url(bootstrap: bootstrap, project: project)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Google Chrome", target.absoluteString]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoAgentSetup", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Chrome is unavailable or could not open the URL"])
        }
    }
}
