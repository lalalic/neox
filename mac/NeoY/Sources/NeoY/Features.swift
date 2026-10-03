import Foundation

enum NeoYFeatureState: String, Codable, Sendable {
    case available, installing, setupRequired = "setup-required", configuring, ready, disabled, failed
}

struct NeoYFeatureCatalogItem: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let package: String
}

struct NeoYFeatureRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var package: String
    var version: String?
    var enabled: Bool
    var state: NeoYFeatureState
    var provider: String?
    var mcpURL: String?
    var error: String?
}

struct NeoYFeatureActionResult: Codable, Sendable {
    let id: String
    let action: String
    let ok: Bool
    let output: String
    let state: NeoYFeatureState?
}

struct NeoYFeatureManifest: Codable, Sendable {
    struct Runtime: Codable, Sendable {
        let type: String
        let serviceScript: String
        let initScript: String
        let doctorScript: String
        let defaultInstance: String
    }
    struct MCP: Codable, Sendable {
        let provider: String
        let endpointFromConfig: String?
        let defaultHost: String
        let defaultPort: Int
    }
    struct Setup: Codable, Sendable {
        let required: Bool
        let bootstrap: String
        let manual: String
        let mode: String
    }
    struct Remote: Codable, Sendable { let `default`: Bool }

    let schemaVersion: Int
    let id: String
    let name: String
    let description: String
    let version: String
    let runtime: Runtime
    let mcp: MCP
    let setup: Setup
    let remote: Remote
}

enum NeoYFeatureCatalog {
    static var all: [NeoYFeatureCatalogItem] {
        guard let url = Bundle.main.url(forResource: "features", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([NeoYFeatureCatalogItem].self, from: data) else {
            return []
        }
        return items
    }
}

actor NeoYFeatureManager {
    static let shared = NeoYFeatureManager()

    private let root = NeoYPaths.supportDirectory.appendingPathComponent("products", isDirectory: true)
    private let stateURL = NeoYPaths.supportDirectory.appendingPathComponent("features.json")

    func records() -> [NeoYFeatureRecord] { loadRecords() }
    func record(id: String) -> NeoYFeatureRecord? { loadRecords().first { $0.id == id } }
    func enabledMCPServers() -> [NeoYMCPServerConfiguration] {
        loadRecords().compactMap { record in
            guard record.enabled, let provider = record.provider, let url = record.mcpURL else { return nil }
            return NeoYMCPServerConfiguration(name: provider, url: url, isEnabled: true)
        }
    }

    func action(id: String, action: String) async throws -> NeoYFeatureActionResult {
        guard let record = record(id: id) else {
            throw NSError(domain: "NeoYFeature", code: 20, userInfo: [NSLocalizedDescriptionKey: "feature '\(id)' is not installed"])
        }
        let manifest = try loadManifest(id: id)
        let script: URL
        let args: [String]
        switch action {
        case "start", "stop", "status", "restart":
            script = packageRoot(id: id).appendingPathComponent(manifest.runtime.serviceScript)
            args = [action, instanceRoot(id: id).path]
        case "doctor":
            script = packageRoot(id: id).appendingPathComponent(manifest.runtime.doctorScript)
            args = [instanceRoot(id: id).path]
        default:
            throw NSError(domain: "NeoYFeature", code: 21, userInfo: [NSLocalizedDescriptionKey: "unsupported feature action '\(action)'"])
        }
        let result = try runNodeScript(script, args: args)
        if action == "start" || action == "restart" || action == "stop" {
            NotificationCenter.default.post(name: .neoYFeaturesChanged, object: nil)
        }
        return NeoYFeatureActionResult(id: id, action: action, ok: result.status == 0, output: result.output, state: record.state)
    }

    func completeSetup(id: String) async throws -> NeoYFeatureActionResult {
        guard record(id: id) != nil else {
            throw NSError(domain: "NeoYFeature", code: 22, userInfo: [NSLocalizedDescriptionKey: "feature '\(id)' is not installed"])
        }
        let doctor = try await action(id: id, action: "doctor")
        guard doctor.ok else { return doctor }
        let started = try await action(id: id, action: "start")
        guard started.ok else { return started }
        guard let record = record(id: id), let urlString = record.mcpURL, let url = URL(string: urlString) else {
            throw NSError(domain: "NeoYFeature", code: 23, userInfo: [NSLocalizedDescriptionKey: "feature MCP endpoint is unavailable"])
        }
        var lastError = "MCP did not become healthy"
        for _ in 0..<20 {
            do {
                var request = URLRequest(url: url, timeoutInterval: 3)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = #"{"jsonrpc":"2.0","id":"feature-setup","method":"tools/list","params":{}}"#.data(using: .utf8)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let rpc = try? JSONSerialization.jsonObject(with: data) as? [String: Any], rpc["result"] != nil {
                    try markReady(id: id)
                    NotificationCenter.default.post(name: .neoYFeaturesChanged, object: nil)
                    return NeoYFeatureActionResult(id: id, action: "complete", ok: true, output: "feature setup complete; MCP healthy at \(urlString)", state: .ready)
                }
                lastError = "MCP returned an unhealthy response"
            } catch { lastError = error.localizedDescription }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return NeoYFeatureActionResult(id: id, action: "complete", ok: false, output: lastError, state: record.state)
    }

    func setEnabled(_ item: NeoYFeatureCatalogItem, enabled: Bool) async throws -> NeoYFeatureRecord {
        if enabled { return try await installAndEnable(item) }
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == item.id }) else {
            return NeoYFeatureRecord(id: item.id, package: item.package, version: nil, enabled: false, state: .available, provider: nil, mcpURL: nil, error: nil)
        }
        if let manifest = try? loadManifest(id: item.id) {
            _ = try? runNodeScript(packageRoot(id: item.id).appendingPathComponent(manifest.runtime.serviceScript), args: ["stop", instanceRoot(id: item.id).path])
        }
        records[index].enabled = false
        records[index].state = .disabled
        try save(records)
        NotificationCenter.default.post(name: .neoYFeaturesChanged, object: nil)
        return records[index]
    }

    func uninstall(_ item: NeoYFeatureCatalogItem) async throws {
        _ = try? await setEnabled(item, enabled: false)
        try? FileManager.default.removeItem(at: productRoot(id: item.id))
        var records = loadRecords()
        records.removeAll { $0.id == item.id }
        try save(records)
        NotificationCenter.default.post(name: .neoYFeaturesChanged, object: nil)
    }

    func startSetup(id: String) async throws {
        let manifest = try loadManifest(id: id)
        guard manifest.setup.mode == "chatgpt-temporary-thread" else { return }
        let package = packageRoot(id: id)
        let bootstrap = try String(contentsOf: package.appendingPathComponent(manifest.setup.bootstrap), encoding: .utf8)
        let manual = try String(contentsOf: package.appendingPathComponent(manifest.setup.manual), encoding: .utf8)
        let prompt = """
        \(bootstrap)

        \(manual)

        NeoY feature id: \(manifest.id)
        Installed instance: \(instanceRoot(id: id).path)

        Use NeoY's setup tool for feature lifecycle checks and actions:
          feature status \(manifest.id)
          feature doctor \(manifest.id)
          feature start \(manifest.id)
          feature complete \(manifest.id)
        Do not invent private shell paths when these standard actions are sufficient.

        Begin setup now. Work interactively with the user and take one concrete configuration step at a time.
        """
        let configURL = productRoot(id: id).appendingPathComponent("setup-chat.json")
        let data = try JSONSerialization.data(withJSONObject: ["prompt": prompt], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)

        let cli = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agents/skills/browser-workspace/bin/browser-workspace")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw NSError(domain: "NeoYFeature", code: 10, userInfo: [NSLocalizedDescriptionKey: "browser-workspace is required for feature setup"])
        }
        let result = try Self.run(cli.path, ["platform", "run", "chatgpt", "temporary-submit", "--config", configURL.path])
        guard result.status == 0 else {
            throw NSError(domain: "NeoYFeature", code: 11, userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        var records = loadRecords()
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].state = .configuring
            records[index].error = nil
            try save(records)
        }
    }

    func markReady(id: String) throws {
        var records = loadRecords()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = .ready
        records[index].error = nil
        try save(records)
    }

    private func installAndEnable(_ item: NeoYFeatureCatalogItem) async throws -> NeoYFeatureRecord {
        try FileManager.default.createDirectory(at: productRoot(id: item.id), withIntermediateDirectories: true)
        var records = loadRecords()
        let initial = NeoYFeatureRecord(id: item.id, package: item.package, version: nil, enabled: true, state: .installing, provider: nil, mcpURL: nil, error: nil)
        if let index = records.firstIndex(where: { $0.id == item.id }) { records[index] = initial } else { records.append(initial) }
        try save(records)

        do {
            guard let npm = Self.executable("npm") else {
                throw NSError(domain: "NeoYFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "npm is required to install NeoY features"])
            }
            let install = try Self.run(npm, ["install", "--omit=dev", "--no-fund", "--no-audit", "--prefix", runtimeRoot(id: item.id).path, "\(item.package)@latest"])
            guard install.status == 0 else { throw NSError(domain: "NeoYFeature", code: 2, userInfo: [NSLocalizedDescriptionKey: install.output]) }
            let manifest = try loadManifest(id: item.id)
            guard manifest.schemaVersion == 1, manifest.id == item.id else {
                throw NSError(domain: "NeoYFeature", code: 3, userInfo: [NSLocalizedDescriptionKey: "unsupported feature manifest"])
            }
            try FileManager.default.createDirectory(at: instanceRoot(id: item.id), withIntermediateDirectories: true)
            let initResult = try runNodeScript(packageRoot(id: item.id).appendingPathComponent(manifest.runtime.initScript), args: [instanceRoot(id: item.id).path])
            guard initResult.status == 0 else { throw NSError(domain: "NeoYFeature", code: 4, userInfo: [NSLocalizedDescriptionKey: initResult.output]) }
            let mcpURL = try discoverMCPURL(manifest: manifest, id: item.id)
            if !manifest.setup.required {
                let service = try runNodeScript(packageRoot(id: item.id).appendingPathComponent(manifest.runtime.serviceScript), args: ["start", instanceRoot(id: item.id).path])
                guard service.status == 0 else { throw NSError(domain: "NeoYFeature", code: 5, userInfo: [NSLocalizedDescriptionKey: service.output]) }
            }
            let record = NeoYFeatureRecord(id: item.id, package: item.package, version: manifest.version, enabled: true,
                state: manifest.setup.required ? .setupRequired : .ready, provider: manifest.mcp.provider, mcpURL: mcpURL, error: nil)
            records = loadRecords()
            if let index = records.firstIndex(where: { $0.id == item.id }) { records[index] = record } else { records.append(record) }
            try save(records)
            NotificationCenter.default.post(name: .neoYFeaturesChanged, object: nil)
            if manifest.setup.required {
                do { try await startSetup(id: item.id) }
                catch {
                    records = loadRecords()
                    if let index = records.firstIndex(where: { $0.id == item.id }) {
                        records[index].state = .setupRequired
                        records[index].error = "setup launch failed: \(error.localizedDescription)"
                        try? save(records)
                    }
                    return records.first(where: { $0.id == item.id }) ?? record
                }
            }
            return record
        } catch {
            records = loadRecords()
            if let index = records.firstIndex(where: { $0.id == item.id }) {
                records[index].state = .failed
                records[index].error = error.localizedDescription
                try? save(records)
            }
            throw error
        }
    }

    private func discoverMCPURL(manifest: NeoYFeatureManifest, id: String) throws -> String {
        let config = instanceRoot(id: id).appendingPathComponent("config/family.config.json")
        if let data = try? Data(contentsOf: config),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bridge = root["browserBridge"] as? [String: Any] {
            let host = bridge["host"] as? String ?? manifest.mcp.defaultHost
            let port = bridge["port"] as? Int ?? manifest.mcp.defaultPort
            return "http://\(host):\(port)/mcp"
        }
        return "http://\(manifest.mcp.defaultHost):\(manifest.mcp.defaultPort)/mcp"
    }

    private func productRoot(id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func runtimeRoot(id: String) -> URL { productRoot(id: id).appendingPathComponent("runtime", isDirectory: true) }
    private func instanceRoot(id: String) -> URL { productRoot(id: id).appendingPathComponent("instance", isDirectory: true) }
    private func packageRoot(id: String) -> URL { runtimeRoot(id: id).appendingPathComponent("node_modules/@lalalic/\(id)", isDirectory: true) }
    private func loadManifest(id: String) throws -> NeoYFeatureManifest {
        let data = try Data(contentsOf: packageRoot(id: id).appendingPathComponent("neo-feature.json"))
        return try JSONDecoder().decode(NeoYFeatureManifest.self, from: data)
    }
    private func runNodeScript(_ url: URL, args: [String]) throws -> (status: Int32, output: String) {
        guard let node = Self.executable("node") else {
            throw NSError(domain: "NeoYFeature", code: 30, userInfo: [NSLocalizedDescriptionKey: "Node.js is required to run NeoY features"])
        }
        return try Self.run(node, [url.path] + args)
    }
    private func loadRecords() -> [NeoYFeatureRecord] {
        guard let data = try? Data(contentsOf: stateURL), let value = try? JSONDecoder().decode([NeoYFeatureRecord].self, from: data) else { return [] }
        return value
    }
    private func save(_ value: [NeoYFeatureRecord]) throws {
        try FileManager.default.createDirectory(at: NeoYPaths.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value.sorted { $0.id < $1.id }).write(to: stateURL, options: .atomic)
    }
    private static func executable(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)", "/usr/bin/\(name)"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func run(_ executable: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
        env["PATH"] = prefix + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension Notification.Name {
    static let neoYFeaturesChanged = Notification.Name("NeoY.featuresChanged")
}
