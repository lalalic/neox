import CryptoKit
import Darwin
import Foundation

@MainActor
final class NeoYTunnelRuntime {
    private struct ListedTunnel: Decodable {
        let id: String
        let name: String
    }

    private struct CachedNamedTunnel: Codable {
        let id: String
        let name: String
        let routedHostname: String
    }

    private let logURL = NeoYPaths.logsDirectory.appendingPathComponent("tunnel.log")
    private let configURL = NeoYPaths.supportDirectory.appendingPathComponent("cloudflared.yml")
    private let pidURL = NeoYPaths.supportDirectory.appendingPathComponent("cloudflared.pid")
    private let cacheURL = NeoYPaths.supportDirectory.appendingPathComponent("named-tunnel.json")
    private var process: Process?
    private var logHandle: FileHandle?
    private var generation = UUID()
    private var desiredSettings = NeoYDeploymentSettings()
    private var desiredEnabled = false
    private var restartTask: Task<Void, Never>?
    private var configWatchTask: Task<Void, Never>?
    private var activeConfigDigest: Data?
    private var rejectedConfigDigest: Data?

    func reconcile(settings: NeoYDeploymentSettings, enabled: Bool) async {
        // Reconciliation can be triggered repeatedly by unrelated provider changes.
        // Do not spawn another connector when the active configuration is unchanged.
        if settings == desiredSettings, enabled == desiredEnabled, process?.isRunning == true { return }
        desiredSettings = settings
        desiredEnabled = enabled
        restartTask?.cancel()
        restartTask = nil
        stopConfigWatcher()
        stopProcess(removePublicURL: true)

        guard enabled, settings.tunnelMode != .off else { return }
        guard let executable = Self.cloudflaredExecutable() else {
            NSLog("Neo tunnel unavailable: cloudflared not found")
            return
        }

        do {
            let arguments: [String]
            switch settings.tunnelMode {
            case .off:
                return
            case .quick:
                arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(settings.mcpPort)"]
            case .named:
                arguments = try await prepareNamedTunnel(executable: executable, settings: settings)
                try writePublicURL("https://\(settings.publicHostname)")
            }
            let initialConfigDigest = settings.tunnelMode == .named
                ? (try? Data(contentsOf: configURL)).map(Self.digest) : nil
            try start(executable: executable, arguments: arguments)
            if settings.tunnelMode == .named {
                startConfigWatcher(executable: executable, initialDigest: initialConfigDigest)
            }
            if settings.tunnelMode == .quick {
                let currentGeneration = generation
                Task { @MainActor [weak self] in
                    await self?.discoverQuickURL(generation: currentGeneration)
                }
            }
        } catch {
            NSLog("Neo tunnel start failed: %@", error.localizedDescription)
            scheduleRestart()
        }
    }

    func stop() {
        desiredEnabled = false
        restartTask?.cancel()
        restartTask = nil
        stopConfigWatcher()
        stopProcess(removePublicURL: true)
    }

    private nonisolated static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func stopConfigWatcher() {
        configWatchTask?.cancel()
        configWatchTask = nil
        activeConfigDigest = nil
        rejectedConfigDigest = nil
    }

    /// Poll the actual content, not just file metadata. This detects in-place edits
    /// and atomic replacement, without ever treating a partial/invalid write as live.
    private func startConfigWatcher(executable: URL, initialDigest: Data?) {
        stopConfigWatcher()
        activeConfigDigest = initialDigest
        configWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.reloadIfConfigChanged(executable: executable)
            }
        }
    }

    private func reloadIfConfigChanged(executable: URL) async {
        guard desiredEnabled, desiredSettings.tunnelMode == .named,
              process?.isRunning == true,
              let bytes = try? Data(contentsOf: configURL) else { return }
        let candidate = Self.digest(bytes)
        guard candidate != activeConfigDigest, candidate != rejectedConfigDigest else { return }
        do {
            guard let cached = try? Data(contentsOf: cacheURL),
                  let tunnel = try? JSONDecoder().decode(CachedNamedTunnel.self, from: cached) else {
                throw NeoYRuntimeControlError.federation("Missing named tunnel identity")
            }
            try Self.validateManagedConfiguration(String(decoding: bytes, as: UTF8.self),
                                                  tunnelID: tunnel.id)
            _ = try await runChecked(executable, ["tunnel", "--config", configURL.path,
                                                   "ingress", "validate"])
            // If the owner saved another revision during validation, validate that
            // revision on the next check instead of restarting with unverified data.
            guard !Task.isCancelled, desiredEnabled,
                  let current = try? Data(contentsOf: configURL),
                  Self.digest(current) == candidate else { return }
            activeConfigDigest = candidate
            rejectedConfigDigest = nil
            NSLog("Neo tunnel configuration validated; reloading connector")
            if let running = process, running.isRunning {
                running.terminate()  // Existing exit handler owns the restart.
                let pid = running.processIdentifier
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                }
            }
        } catch {
            rejectedConfigDigest = candidate
            NSLog("Neo tunnel configuration rejected, keeping active connector: %@",
                  error.localizedDescription)
        }
    }

    private func start(executable: URL, arguments: [String]) throws {
        try FileManager.default.createDirectory(at: NeoYPaths.logsDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        try log.truncate(atOffset: 0)

        let currentGeneration = UUID()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = NeoYProcessEnvironment.childEnvironment()
        child.standardOutput = log
        child.standardError = log
        child.terminationHandler = { [weak self] terminated in
            let detail = "exit=\(terminated.terminationStatus)"
            Task { @MainActor in self?.processExited(generation: currentGeneration, detail: detail) }
        }
        try child.run()

        generation = currentGeneration
        process = child
        logHandle = log
        try String(child.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidURL.path)
        NSLog("Neo tunnel started: pid=%d", child.processIdentifier)
    }

    private func processExited(generation exitedGeneration: UUID, detail: String) {
        guard exitedGeneration == generation else { return }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(at: pidURL)
        try? FileManager.default.removeItem(at: NeoYDeploymentSettingsStore.publicURLFile)
        NSLog("Neo tunnel exited: %@", detail)
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard desiredEnabled, desiredSettings.tunnelMode != .off, restartTask == nil else { return }
        let settings = desiredSettings
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            await self.reconcile(settings: settings, enabled: true)
        }
    }

    private func stopProcess(removePublicURL: Bool) {
        generation = UUID()
        if process == nil { terminatePersistedChildIfNeeded() }
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(at: pidURL)
        if removePublicURL { try? FileManager.default.removeItem(at: NeoYDeploymentSettingsStore.publicURLFile) }
    }

    private func terminatePersistedChildIfNeeded() {
        guard let raw = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(raw), pid > 1 else { return }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard URL(fileURLWithPath: path).lastPathComponent == "cloudflared" else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    private func discoverQuickURL(generation expectedGeneration: UUID) async {
        let pattern = try? NSRegularExpression(pattern: #"https://[a-z0-9-]+\.trycloudflare\.com"#)
        for _ in 0..<120 {
            guard expectedGeneration == generation, process?.isRunning == true else { return }
            if let text = try? String(contentsOf: logURL, encoding: .utf8),
               let pattern,
               let match = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range, in: text) {
                do {
                    try writePublicURL(String(text[range]))
                    NSLog("Neo quick tunnel ready")
                } catch {
                    NSLog("Neo quick tunnel URL save failed: %@", error.localizedDescription)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard expectedGeneration == generation else { return }
        NSLog("Neo quick tunnel URL was not discovered")
        stopProcess(removePublicURL: true)
        scheduleRestart()
    }

    private func prepareNamedTunnel(executable: URL, settings: NeoYDeploymentSettings) async throws -> [String] {
        let hostname = settings.publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            throw NeoYRuntimeControlError.federation("named tunnel requires a public hostname")
        }
        let name = settings.tunnelName.isEmpty ? Self.defaultTunnelName(hostname: hostname) : settings.tunnelName
        let saved = (try? Data(contentsOf: cacheURL)).flatMap {
            try? JSONDecoder().decode(CachedNamedTunnel.self, from: $0)
        }
        let credentialsPath: (String) -> String = { id in
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cloudflared/\(id).json").path
        }
        let tunnel: ListedTunnel
        if let saved, saved.name == name,
           UUID(uuidString: saved.id) != nil,
           FileManager.default.fileExists(atPath: credentialsPath(saved.id)) {
            // A running named tunnel should not depend on Cloudflare's management API.
            tunnel = ListedTunnel(id: saved.id, name: saved.name)
        } else {
            var tunnels = try await listTunnels(executable: executable)
            if !tunnels.contains(where: { $0.name == name }) {
                _ = try await runChecked(executable, ["tunnel", "create", name])
                tunnels = try await listTunnels(executable: executable)
            }
            guard let existing = tunnels.first(where: { $0.name == name }) else {
                throw NeoYRuntimeControlError.federation("Cloudflare tunnel '\(name)' was not created")
            }
            tunnel = existing
        }
        if saved?.id != tunnel.id || saved?.routedHostname != hostname {
            _ = try await runChecked(executable, ["tunnel", "route", "dns", name, hostname])
        }

        let credentials = credentialsPath(tunnel.id)
        if FileManager.default.fileExists(atPath: configURL.path) {
            // The YAML is the owner-maintained ingress source of truth. Never
            // regenerate it on an app restart or unrelated settings change.
            let existing = try String(contentsOf: configURL, encoding: .utf8)
            try Self.validateManagedConfiguration(existing, tunnelID: tunnel.id)
        } else {
            let config = try Self.namedTunnelConfiguration(
                tunnelID: tunnel.id, credentials: credentials, settings: settings)
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        }
        let cache = CachedNamedTunnel(id: tunnel.id, name: name, routedHostname: hostname)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        return ["tunnel", "--config", configURL.path, "run", tunnel.id]
    }

    nonisolated static func namedTunnelConfiguration(
        tunnelID: String, credentials: String, settings: NeoYDeploymentSettings
    ) throws -> String {
        let validSettings = try settings.validated()
        var lines = [
            "tunnel: \(tunnelID)",
            "credentials-file: \(credentials)",
            "ingress:",
            "  - hostname: \(validSettings.publicHostname)",
            "    service: http://127.0.0.1:\(validSettings.mcpPort)",
        ]
        lines.append("  - service: http_status:404")
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func validateManagedConfiguration(_ config: String, tunnelID: String) throws {
        let ids = config.split(separator: "\n").compactMap { line -> String? in
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            guard cleaned.hasPrefix("tunnel:") else { return nil }
            return cleaned.dropFirst("tunnel:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard ids == [tunnelID] else {
            throw NeoYRuntimeControlError.federation(
                "Existing cloudflared.yml is for a different tunnel; refusing to overwrite")
        }
    }

    private func listTunnels(executable: URL) async throws -> [ListedTunnel] {
        let data = try await runChecked(executable, ["tunnel", "list", "--output", "json"])
        return try JSONDecoder().decode([ListedTunnel].self, from: data)
    }

    private func runChecked(_ executable: URL, _ arguments: [String]) async throws -> Data {
        let result = try await Self.run(executable: executable, arguments: arguments)
        guard result.status == 0 else {
            let data = result.error.isEmpty ? result.output : result.error
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NeoYRuntimeControlError.federation(output.isEmpty ? "cloudflared failed" : output)
        }
        return result.output
    }

    private func writePublicURL(_ value: String) throws {
        try FileManager.default.createDirectory(at: NeoYPaths.supportDirectory, withIntermediateDirectories: true)
        try value.write(to: NeoYDeploymentSettingsStore.publicURLFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: NeoYDeploymentSettingsStore.publicURLFile.path
        )
    }

    nonisolated static func defaultTunnelName(hostname: String) -> String {
        let slug = hostname.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(32)
        let digest = SHA256.hash(data: Data(hostname.lowercased().utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        return "neoy-\(slug)-\(digest)"
    }

    nonisolated private static func cloudflaredExecutable() -> URL? {
        let environment = NeoYProcessEnvironment.childEnvironment()
        var candidates = (environment["PATH"] ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("cloudflared") }
        candidates += ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
            .map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    nonisolated private static func run(executable: URL, arguments: [String]) async throws
        -> (status: Int32, output: Data, error: Data) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = NeoYProcessEnvironment.childEnvironment()
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { terminated in
                continuation.resume(returning: (
                    terminated.terminationStatus,
                    output.fileHandleForReading.readDataToEndOfFile(),
                    error.fileHandleForReading.readDataToEndOfFile()
                ))
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}
