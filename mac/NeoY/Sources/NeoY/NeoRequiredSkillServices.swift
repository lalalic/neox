import Foundation

/// Maintains only services declared by approved Skill owners.
/// PM2 service commands stay owned by the Skill's own setup script.
enum NeoRequiredSkillServices {
    struct Owner {
        let name: String
        let services: [String]
        let setupScript: [String]
    }

    static let requiredOwners = [
        Owner(name: "events-bus", services: ["nats", "history"],
              setupScript: ["cli", "events-bus.mjs"]),
        Owner(name: "agents-relay", services: ["daemon", "dashboard-tunnel"],
              setupScript: ["bin", "services.mjs"]),
    ]

    static let optionalOwners = [
        Owner(name: "wechat-bro", services: ["daemon", "orchestrator"],
              setupScript: ["bin", "services.mjs"]),
    ]

    /// Does not start an unselected optional Skill or modify unrelated PM2 services.
    static func owners(optionalEnabled: Set<String>) -> [Owner] {
        requiredOwners + optionalOwners.filter { optionalEnabled.contains($0.name) }
    }

    static func missingServices(for owner: Owner, states: [String: String]) -> [String] {
        owner.services.filter { states["\(owner.name)/\($0)"] == nil }
    }

    static func unhealthyServices(for owner: Owner, states: [String: String]) -> [String] {
        owner.services.filter { states["\(owner.name)/\($0)"] != "online" }
    }

    private static func run(_ command: String, _ arguments: [String],
                            directory: URL? = nil, timeout: TimeInterval = 40) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, configured in configured }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Drain before waiting so verbose child processes cannot fill a pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let response = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoSkillServices", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "\(command) \(arguments.first ?? "") exited \(process.terminationStatus)"])
        }
        return response
    }

    private static func records() throws -> [[String: Any]] {
        let data = Data(try run("npx", ["--yes", "pm2", "jlist"]).utf8)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "NeoSkillServices", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid PM2 status inventory"])
        }
        return entries
    }

    private static func states() throws -> [String: String] {
        let records = try records()
        var output: [String: String] = [:]
        for record in records {
            guard let name = record["name"] as? String,
                  let environment = record["pm2_env"] as? [String: Any],
                  let status = environment["status"] as? String else { continue }
            output[name] = status
        }
        return output
    }

    private static func scriptPath(for owner: Owner) throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills/\(owner.name)", isDirectory: true)
        let script = owner.setupScript.reduce(directory) { $0.appendingPathComponent($1) }
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw NSError(domain: "NeoSkillServices", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Skill \(owner.name) has no installed service setup script"])
        }
        return script
    }

    static func eventsBusRuntimeReady(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory
            .appendingPathComponent("node_modules/@nats-io/transport-node/package.json").path)
    }

    private static func ensureSupportedServiceContract(for owner: Owner) throws {
        guard owner.name == "events-bus" else { return }
        let script = try scriptPath(for: owner)
        let skillRoot = script.deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: script, encoding: .utf8)
        if !code.contains("serviceman") {
            // Legacy Events Bus setup registers unqualified PM2 names.
            // Only upgrade an approved global installation.
            try NeoCLISetup.updateManagedSkill("events-bus", automatic: true)
            let updated = try String(contentsOf: script, encoding: .utf8)
            guard updated.contains("serviceman") else {
                throw NSError(domain: "NeoSkillServices", code: 4,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Installed events-bus Skill lacks namespaced service setup"])
            }
        }
        // A global Skill installer copies source, not npm node_modules.
        // Install locked runtime dependencies before starting its MCP provider
        // or migrating the existing history service.
        if !eventsBusRuntimeReady(at: skillRoot) {
            guard FileManager.default.fileExists(atPath: skillRoot
                .appendingPathComponent("package-lock.json").path) else {
                throw NSError(domain: "NeoSkillServices", code: 7,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Events Bus has no dependency lockfile"])
            }
            _ = try run("npm", ["ci", "--omit=dev", "--no-audit", "--no-fund"],
                        directory: skillRoot, timeout: 120)
            guard eventsBusRuntimeReady(at: skillRoot) else {
                throw NSError(domain: "NeoSkillServices", code: 8,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Events Bus npm dependencies missing after setup"])
            }
        }
    }

    static func isLegacyEventsHistory(_ path: String?) -> Bool {
        path?.hasSuffix("/events-bus/api/server.mjs") == true
    }

    private static func migrateLegacyHistory(_ owner: Owner) throws {
        try ensureSupportedServiceContract(for: owner)
        guard let legacy = try records().first(where: { $0["name"] as? String == "events-bus-service" }),
              let environment = legacy["pm2_env"] as? [String: Any],
              isLegacyEventsHistory(environment["pm_exec_path"] as? String) else {
            throw NSError(domain: "NeoSkillServices", code: 5,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Unexpected legacy events-bus service; migration refused"])
        }
        let wasOnline = environment["status"] as? String == "online"
        if wasOnline { _ = try run("npx", ["--yes", "pm2", "stop", "events-bus-service"]) }
        do {
            try setup(owner)
            guard try states()["events-bus/history"] == "online" else {
                throw NSError(domain: "NeoSkillServices", code: 6,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Namespaced history service failed startup"])
            }
            _ = try run("npx", ["--yes", "pm2", "delete", "events-bus-service"])
            // Old, failed NATS registration may be removed only when it is
            // certainly the same legacy binary and the namespaced NATS is online.
            if try states()["events-bus/nats"] == "online",
               let old = try records().first(where: { $0["name"] as? String == "events-bus" }),
               let pm = old["pm2_env"] as? [String: Any],
               pm["status"] as? String == "errored",
               (pm["pm_exec_path"] as? String)?.hasSuffix("/nats-server") == true {
                _ = try run("npx", ["--yes", "pm2", "delete", "events-bus"])
            }
        } catch {
            if (try? states()["events-bus/history"]) != nil {
                _ = try? run("npx", ["--yes", "pm2", "delete", "events-bus/history"])
            }
            if wasOnline { _ = try? run("npx", ["--yes", "pm2", "restart", "events-bus-service"]) }
            throw error
        }
    }

    private static func setup(_ owner: Owner) throws {
        try ensureSupportedServiceContract(for: owner)
        _ = try run("node", [try scriptPath(for: owner).path, "setup"])
    }

    /// Called on a detached task at launch and periodically. Setup only repairs
    /// missing registrations. Existing stopped services use their owner's
    /// serviceman lifecycle, never a guessed process command.
    static func reconcile(optionalEnabled: Set<String> = []) throws {
        let selected = owners(optionalEnabled: optionalEnabled)
        var inventory = try states()
        var installedService = false
        for owner in selected where !missingServices(for: owner, states: inventory).isEmpty {
            do {
                if owner.name == "events-bus", inventory["events-bus-service"] != nil,
                   inventory["events-bus/history"] == nil {
                    try migrateLegacyHistory(owner)
                } else {
                    try setup(owner)
                }
                installedService = true
            } catch {
                NSLog("Neo Skill %@ service setup: %@", owner.name, error.localizedDescription)
            }
            inventory = try states()
        }
        for owner in selected {
            for service in owner.services {
                let id = "\(owner.name)/\(service)"
                guard let state = inventory[id] else {
                    NSLog("Neo Skill required service missing after setup: %@", id)
                    continue
                }
                guard state != "online" else { continue }
                do {
                    _ = try run("serviceman", ["restart", "--skill", owner.name,
                                                "--service", service, "--apply"])
                } catch {
                    NSLog("Neo Skill %@ recovery failed: %@", id, error.localizedDescription)
                }
            }
        }
        if installedService { _ = try run("npx", ["--yes", "pm2", "save"]) }
        let verified = try states()
        let unhealthy = selected.flatMap { owner in
            unhealthyServices(for: owner, states: verified).map { "\(owner.name)/\($0)" }
        }
        if !unhealthy.isEmpty {
            throw NSError(domain: "NeoSkillServices", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Skill services unhealthy: \(unhealthy.joined(separator: ", "))"])
        }
    }
}

/// Reconciles *user-enabled* Neo Projects. A project's own executable owns
/// setup, daemon management, and health; NeoY only owns app-start recovery.
/// This adds no MCP tool, duplicate scheduler, or project-specific daemon.
enum NeoProjectLifecycleServices {
    struct Preferences: Codable {
        var enabled: [String]
    }

    static var configurationURL: URL {
        NeoYPaths.supportDirectory.appendingPathComponent("projects.json")
    }

    static func validName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }

    static func desiredProjects(from data: Data) throws -> [String] {
        let names = try JSONDecoder().decode(Preferences.self, from: data).enabled
        guard names.allSatisfy(validName) else {
            throw NSError(domain: "NeoProjects", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid enabled project name"])
        }
        return Array(Set(names)).sorted()
    }

    static func permittedEntrypoint(_ candidate: URL, workspace: URL) -> Bool {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let base = workspace.resolvingSymlinksInPath().standardizedFileURL
        return resolved.lastPathComponent == "neo-project"
            && resolved.path.hasPrefix(base.path + "/")
    }

    static func needsStart(_ state: [String: Any]) -> Bool {
        state["running"] as? Bool != true
    }

    private static func run(_ command: URL, _ arguments: [String],
                            directory: URL? = nil, timeout: TimeInterval = 100) throws -> Data {
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, configured in configured }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "NeoProjects", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "Project lifecycle command failed (exit \(process.terminationStatus))"])
        }
        return data
    }

    private static func resolve(_ name: String) throws -> URL {
        let executable = URL(fileURLWithPath: "/usr/bin/env")
        let data = try run(executable, ["neo", "project", "resolve", name], timeout: 20)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lifecycle = object["lifecycle"] as? [String: Any],
              let entry = lifecycle["entrypoint"] as? String else {
            throw NSError(domain: "NeoProjects", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Project has no lifecycle entrypoint"])
        }
        let candidate = URL(fileURLWithPath: entry)
        let workspace = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Workspace")
        guard permittedEntrypoint(candidate, workspace: workspace),
              FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw NSError(domain: "NeoProjects", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Project lifecycle entrypoint is not trusted or executable"])
        }
        return candidate
    }

    private static func state(_ script: URL) throws -> [String: Any] {
        let data = try run(script, ["status"], directory: script.deletingLastPathComponent(), timeout: 30)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NeoProjects", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid project lifecycle status"])
        }
        return object
    }

    /// Called after required Skill recovery, then periodically by Neo.app.
    /// A missing preferences file never starts arbitrary discovered projects.
    static func reconcile(configURL: URL = configurationURL) throws {
        let data: Data
        do { data = try Data(contentsOf: configURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError { return }
        let projects = try desiredProjects(from: data)
        for name in projects {
            do {
                let script = try resolve(name)
                if needsStart(try state(script)) {
                    _ = try run(script, ["setup"], directory: script.deletingLastPathComponent())
                    _ = try run(script, ["start"], directory: script.deletingLastPathComponent())
                } else {
                    do { _ = try run(script, ["health"], directory: script.deletingLastPathComponent(), timeout: 30) }
                    catch { _ = try run(script, ["restart"], directory: script.deletingLastPathComponent()) }
                }
                _ = try run(script, ["health"], directory: script.deletingLastPathComponent(), timeout: 30)
            } catch {
                // A failing optional Project cannot block Neo's MCP or other Projects.
                NSLog("Neo Project %@ lifecycle recovery: %@", name, error.localizedDescription)
            }
        }
    }
}
