import Foundation

struct NeoYStartupServiceStatus: Codable, Equatable, Sendable {
    let name: String
    let enabled: Bool
    let running: Bool
    let processIdentifier: Int32?
    let lastExitCode: Int32?
    let error: String?
}

@MainActor
final class NeoYStartupSupervisor {
    private struct Running {
        let process: Process
        let stdout: FileHandle
        let stderr: FileHandle
    }

    private var desired: [String: NeoYStartupServiceConfiguration] = [:]
    private var running: [String: Running] = [:]
    private var exitCodes: [String: Int32] = [:]
    private var errors: [String: String] = [:]
    private let logsDirectory: URL

    init(logsDirectory: URL = NeoYPaths.supportDirectory.appendingPathComponent("logs", isDirectory: true)) {
        self.logsDirectory = logsDirectory
    }

    func reconcile(_ configurations: [NeoYStartupServiceConfiguration]) {
        desired = Dictionary(uniqueKeysWithValues: configurations.map { ($0.name, $0) })
        for name in Array(running.keys) where desired[name]?.isEnabled != true {
            stop(name)
        }
        for configuration in configurations where configuration.isEnabled && running[configuration.name] == nil {
            start(configuration)
        }
    }

    func stopAll() {
        for name in Array(running.keys) { stop(name) }
    }

    func statuses(configurations: [NeoYStartupServiceConfiguration]) -> [NeoYStartupServiceStatus] {
        configurations.sorted { $0.name < $1.name }.map { config in
            let process = running[config.name]?.process
            return NeoYStartupServiceStatus(
                name: config.name,
                enabled: config.isEnabled,
                running: process?.isRunning == true,
                processIdentifier: process?.isRunning == true ? process?.processIdentifier : nil,
                lastExitCode: exitCodes[config.name],
                error: errors[config.name]
            )
        }
    }

    private func start(_ configuration: NeoYStartupServiceConfiguration) {
        do {
            try configuration.validate()
            guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
                throw NeoYRuntimeControlError.startup("executable is not runnable: \(configuration.executable)")
            }
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            let stdout = try openLog(configuration.name, suffix: "out")
            let stderr = try openLog(configuration.name, suffix: "err")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: configuration.executable)
            process.arguments = configuration.arguments
            if let cwd = configuration.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
            }
            var environment = ProcessInfo.processInfo.environment
            environment.merge(configuration.environment) { _, new in new }
            process.environment = environment
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { [weak self] process in
                let code = process.terminationStatus
                Task { @MainActor [weak self] in self?.terminated(configuration.name, exitCode: code) }
            }
            try process.run()
            running[configuration.name] = Running(process: process, stdout: stdout, stderr: stderr)
            errors[configuration.name] = nil
        } catch {
            errors[configuration.name] = error.localizedDescription
        }
    }

    private func stop(_ name: String) {
        guard let current = running.removeValue(forKey: name) else { return }
        current.process.terminationHandler = nil
        if current.process.isRunning { current.process.terminate() }
        try? current.stdout.close()
        try? current.stderr.close()
    }

    private func terminated(_ name: String, exitCode: Int32) {
        guard let current = running.removeValue(forKey: name) else { return }
        try? current.stdout.close()
        try? current.stderr.close()
        exitCodes[name] = exitCode
        guard let configuration = desired[name], configuration.isEnabled else { return }
        let shouldRestart = configuration.restartPolicy == .always ||
            (configuration.restartPolicy == .onFailure && exitCode != 0)
        guard shouldRestart else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.running[name] == nil, self.desired[name]?.isEnabled == true else { return }
            self.start(configuration)
        }
    }

    private func openLog(_ name: String, suffix: String) throws -> FileHandle {
        let url = logsDirectory.appendingPathComponent("\(name).\(suffix).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}

enum NeoYRuntimeControlError: LocalizedError {
    case startup(String)
    case federation(String)
    case event(String)

    var errorDescription: String? {
        switch self {
        case .startup(let value), .federation(let value), .event(let value): value
        }
    }
}
