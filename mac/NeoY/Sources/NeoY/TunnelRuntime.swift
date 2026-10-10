import CryptoKit
import Darwin
import Foundation

@MainActor
final class NeoYTunnelRuntime {
    private struct ListedTunnel: Decodable {
        let id: String
        let name: String
    }

    private let logURL = NeoYPaths.logsDirectory.appendingPathComponent("tunnel.log")
    private let configURL = NeoYPaths.supportDirectory.appendingPathComponent("cloudflared.yml")
    private let pidURL = NeoYPaths.supportDirectory.appendingPathComponent("cloudflared.pid")
    private var process: Process?
    private var logHandle: FileHandle?
    private var generation = UUID()
    private var desiredSettings = NeoYDeploymentSettings()
    private var desiredEnabled = false
    private var restartTask: Task<Void, Never>?

    func reconcile(settings: NeoYDeploymentSettings, enabled: Bool) async {
        desiredSettings = settings
        desiredEnabled = enabled
        restartTask?.cancel()
        restartTask = nil
        stopProcess(removePublicURL: true)

        guard enabled, settings.tunnelMode != .off else { return }
        guard let executable = Self.cloudflaredExecutable() else {
            NSLog("NeoY tunnel unavailable: cloudflared not found")
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
            try start(executable: executable, arguments: arguments)
            if settings.tunnelMode == .quick {
                let currentGeneration = generation
                Task { @MainActor [weak self] in
                    await self?.discoverQuickURL(generation: currentGeneration)
                }
            }
        } catch {
            NSLog("NeoY tunnel start failed: %@", error.localizedDescription)
            scheduleRestart()
        }
    }

    func stop() {
        desiredEnabled = false
        restartTask?.cancel()
        restartTask = nil
        stopProcess(removePublicURL: true)
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
        NSLog("NeoY tunnel started: pid=%d", child.processIdentifier)
    }

    private func processExited(generation exitedGeneration: UUID, detail: String) {
        guard exitedGeneration == generation else { return }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        try? FileManager.default.removeItem(at: pidURL)
        try? FileManager.default.removeItem(at: NeoYDeploymentSettingsStore.publicURLFile)
        NSLog("NeoY tunnel exited: %@", detail)
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
                    NSLog("NeoY quick tunnel ready")
                } catch {
                    NSLog("NeoY quick tunnel URL save failed: %@", error.localizedDescription)
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard expectedGeneration == generation else { return }
        NSLog("NeoY quick tunnel URL was not discovered")
        stopProcess(removePublicURL: true)
        scheduleRestart()
    }

    private func prepareNamedTunnel(executable: URL, settings: NeoYDeploymentSettings) async throws -> [String] {
        let hostname = settings.publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            throw NeoYRuntimeControlError.federation("named tunnel requires a public hostname")
        }
        let name = settings.tunnelName.isEmpty ? Self.defaultTunnelName(hostname: hostname) : settings.tunnelName
        var tunnels = try await listTunnels(executable: executable)
        if !tunnels.contains(where: { $0.name == name }) {
            _ = try await runChecked(executable, ["tunnel", "create", name])
            tunnels = try await listTunnels(executable: executable)
        }
        guard let tunnel = tunnels.first(where: { $0.name == name }) else {
            throw NeoYRuntimeControlError.federation("Cloudflare tunnel '\(name)' was not created")
        }
        _ = try await runChecked(executable, ["tunnel", "route", "dns", name, hostname])

        let credentials = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared/\(tunnel.id).json").path
        let config = """
        tunnel: \(tunnel.id)
        credentials-file: \(credentials)
        ingress:
          - hostname: \(hostname)
            service: http://127.0.0.1:\(settings.mcpPort)
          - service: http_status:404
        """
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return ["tunnel", "--config", configURL.path, "run", tunnel.id]
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
