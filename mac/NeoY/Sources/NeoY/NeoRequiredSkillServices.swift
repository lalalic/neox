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

    private static func run(_ command: String, _ arguments: [String], timeout: TimeInterval = 40) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
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

    private static func states() throws -> [String: String] {
        let data = Data(try run("npx", ["--yes", "pm2", "jlist"]).utf8)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "NeoSkillServices", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid PM2 status inventory"])
        }
        var output: [String: String] = [:]
        for record in records {
            guard let name = record["name"] as? String,
                  let environment = record["pm2_env"] as? [String: Any],
                  let status = environment["status"] as? String else { continue }
            output[name] = status
        }
        return output
    }

    private static func setup(_ owner: Owner) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills/\(owner.name)", isDirectory: true)
        let script = owner.setupScript.reduce(directory) { $0.appendingPathComponent($1) }
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw NSError(domain: "NeoSkillServices", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Skill \(owner.name) has no installed service setup script"])
        }
        _ = try run("node", [script.path, "setup"])
    }

    /// Called on a detached task at launch and periodically. Setup only repairs
    /// missing registrations. Existing stopped services use their owner's
    /// serviceman lifecycle, never a guessed process command.
    static func reconcile(optionalEnabled: Set<String> = []) throws {
        let selected = owners(optionalEnabled: optionalEnabled)
        var inventory = try states()
        var installedService = false
        for owner in selected where !missingServices(for: owner, states: inventory).isEmpty {
            do { try setup(owner) }
            catch { NSLog("Neo Skill %@ service setup: %@", owner.name, error.localizedDescription) }
            installedService = true
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
