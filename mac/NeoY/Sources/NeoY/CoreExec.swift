import Foundation
import Darwin

private struct NeoYExecResult: Codable, Sendable {
    let exitCode: Int32
    let signal: Int32?
    let timedOut: Bool
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
}

private struct NeoYBackgroundJobStatus: Codable, Sendable {
    let id: String
    let pid: Int32
    let running: Bool
    let exitCode: Int32?
    let startedAt: Date
    let command: String
    let cwd: String
}

private struct NeoYPTYStatus: Codable, Sendable {
    let id: String
    let pid: Int32
    let running: Bool
    let exitCode: Int32?
    let command: String
    let cwd: String
    let cols: Int
    let rows: Int
}

actor NeoYExecService {
    private final class BackgroundJob {
        let id: String
        let process: Process
        let stdoutURL: URL
        let stderrURL: URL
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        let startedAt: Date
        let command: String
        let cwd: String

        init(
            id: String, process: Process, stdoutURL: URL, stderrURL: URL,
            stdoutHandle: FileHandle, stderrHandle: FileHandle,
            startedAt: Date, command: String, cwd: String
        ) {
            self.id = id
            self.process = process
            self.stdoutURL = stdoutURL
            self.stderrURL = stderrURL
            self.stdoutHandle = stdoutHandle
            self.stderrHandle = stderrHandle
            self.startedAt = startedAt
            self.command = command
            self.cwd = cwd
        }

        deinit {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
    }

    private final class PTYSession {
        let id: String
        let process: Process
        let master: FileHandle
        let startedAt: Date
        let command: String
        let cwd: String
        var cols: Int
        var rows: Int

        init(id: String, process: Process, master: FileHandle, command: String, cwd: String, cols: Int, rows: Int) {
            self.id = id
            self.process = process
            self.master = master
            self.startedAt = Date()
            self.command = command
            self.cwd = cwd
            self.cols = cols
            self.rows = rows
        }

        deinit { try? master.close() }
    }

    private var jobs: [String: BackgroundJob] = [:]
    private var ptys: [String: PTYSession] = [:]
    private let jobsDirectory: URL

    init() {
        jobsDirectory = NeoYPaths.supportDirectory.appendingPathComponent("core-jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: jobsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: jobsDirectory.path)
    }

    func execute(_ raw: String) async throws -> String {
        let parsed = try NeoYCommandLine.parse(raw)
        guard let verb = parsed.tokens.first else { return Self.help }
        switch verb {
        case "help": return Self.help
        case "run": return try run(parsed)
        case "start": return try start(parsed)
        case "jobs": return listJobs()
        case "status": return try status(parsed.tokens)
        case "logs": return try logs(parsed.tokens)
        case "stop": return try stop(parsed.tokens)
        case "pty": return try pty(parsed)
        default: throw NeoYCoreError.invalidCommand("unknown mac.exec command '\(verb)'; run 'help'")
        }
    }

    private func run(_ parsed: NeoYCommandLine.Parsed) throws -> String {
        let options = try parseLaunchOptions(Array(parsed.tokens.dropFirst()))
        guard let command = parsed.remainder, !command.isEmpty else {
            throw NeoYCoreError.missingArgument("run [--cwd PATH] [--timeout SECONDS] -- <shell command>")
        }
        let result = try Self.runProcess(
            command: command,
            cwd: options.cwd,
            environment: options.environment,
            stdin: options.stdin,
            timeoutSeconds: options.timeoutSeconds,
            maxOutputBytes: options.maxOutputBytes
        )
        return NeoYCoreJSON.encode(result)
    }

    private func start(_ parsed: NeoYCommandLine.Parsed) throws -> String {
        let options = try parseLaunchOptions(Array(parsed.tokens.dropFirst()))
        guard let command = parsed.remainder, !command.isEmpty else {
            throw NeoYCoreError.missingArgument("start [--cwd PATH] -- <shell command>")
        }

        let id = UUID().uuidString.lowercased()
        let stdoutURL = jobsDirectory.appendingPathComponent("\(id).stdout.log")
        let stderrURL = jobsDirectory.appendingPathComponent("\(id).stderr.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: options.cwd)
        process.environment = Self.mergedEnvironment(options.environment)
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let job = BackgroundJob(
            id: id, process: process, stdoutURL: stdoutURL, stderrURL: stderrURL,
            stdoutHandle: stdout, stderrHandle: stderr, startedAt: Date(),
            command: command, cwd: options.cwd
        )
        jobs[id] = job
        return NeoYCoreJSON.encode(status(for: job))
    }

    private func listJobs() -> String {
        NeoYCoreJSON.encode(jobs.values.sorted { $0.startedAt > $1.startedAt }.map(status(for:)))
    }

    private func status(_ tokens: [String]) throws -> String {
        guard tokens.count == 2, let job = jobs[tokens[1]] else {
            throw NeoYCoreError.notFound("background job not found; usage: status <job-id>")
        }
        return NeoYCoreJSON.encode(status(for: job))
    }

    private func logs(_ tokens: [String]) throws -> String {
        guard tokens.count >= 2, let job = jobs[tokens[1]] else {
            throw NeoYCoreError.notFound("background job not found; usage: logs <job-id> [--max-bytes N]")
        }
        var maxBytes = 100_000
        if let index = tokens.firstIndex(of: "--max-bytes"), tokens.indices.contains(index + 1),
           let value = Int(tokens[index + 1]) {
            maxBytes = min(max(value, 1_024), 8_000_000)
        }
        struct Logs: Codable {
            let id: String
            let stdout: String
            let stderr: String
        }
        return NeoYCoreJSON.encode(Logs(
            id: job.id,
            stdout: Self.tail(job.stdoutURL, maxBytes: maxBytes),
            stderr: Self.tail(job.stderrURL, maxBytes: maxBytes)
        ))
    }

    private func stop(_ tokens: [String]) throws -> String {
        guard tokens.count == 2, let job = jobs[tokens[1]] else {
            throw NeoYCoreError.notFound("background job not found; usage: stop <job-id>")
        }
        if job.process.isRunning {
            job.process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while job.process.isRunning && Date() < deadline { usleep(20_000) }
            if job.process.isRunning { kill(job.process.processIdentifier, SIGKILL) }
        }
        return NeoYCoreJSON.encode(status(for: job))
    }

    private func pty(_ parsed: NeoYCommandLine.Parsed) throws -> String {
        guard parsed.tokens.count >= 2 else {
            throw NeoYCoreError.missingArgument("pty <start|read|write|resize|signal|close> ...")
        }
        switch parsed.tokens[1] {
        case "start":
            let options = try parsePTYOptions(Array(parsed.tokens.dropFirst(2)))
            guard let command = parsed.remainder, !command.isEmpty else {
                throw NeoYCoreError.missingArgument("pty start [--cwd PATH] [--cols N] [--rows N] -- <shell command>")
            }
            return try startPTY(command: command, options: options)
        case "read":
            guard parsed.tokens.count >= 3, let session = ptys[parsed.tokens[2]] else {
                throw NeoYCoreError.notFound("PTY session not found; usage: pty read <id> [--max-bytes N]")
            }
            var maxBytes = 65_536
            if let i = parsed.tokens.firstIndex(of: "--max-bytes"), parsed.tokens.indices.contains(i + 1),
               let value = Int(parsed.tokens[i + 1]) {
                maxBytes = min(max(value, 1), 1_000_000)
            }
            return readPTY(session, maxBytes: maxBytes)
        case "write":
            guard parsed.tokens.count >= 3, let session = ptys[parsed.tokens[2]] else {
                throw NeoYCoreError.notFound("PTY session not found; usage: pty write <id> -- <text>")
            }
            guard let text = parsed.remainder else { throw NeoYCoreError.missingArgument("text after --") }
            try session.master.write(contentsOf: Data(text.utf8))
            return "{\"ok\":true,\"bytes_written\":\(text.utf8.count)}"
        case "resize":
            guard parsed.tokens.count == 5, let session = ptys[parsed.tokens[2]],
                  let cols = Int(parsed.tokens[3]), let rows = Int(parsed.tokens[4]),
                  (20...500).contains(cols), (5...200).contains(rows) else {
                throw NeoYCoreError.invalidCommand("usage: pty resize <id> <cols:20-500> <rows:5-200>")
            }
            try resizePTY(session, cols: cols, rows: rows)
            return NeoYCoreJSON.encode(ptyStatus(session))
        case "signal":
            guard parsed.tokens.count == 4, let session = ptys[parsed.tokens[2]] else {
                throw NeoYCoreError.invalidCommand("usage: pty signal <id> <INT|TERM|KILL|HUP|WINCH>")
            }
            let sig = try Self.signalNumber(parsed.tokens[3])
            guard kill(session.process.processIdentifier, sig) == 0 else {
                throw NeoYCoreError.operationFailed("signal failed: \(String(cString: strerror(errno)))")
            }
            return "{\"ok\":true,\"signal\":\"\(parsed.tokens[3])\"}"
        case "close":
            guard parsed.tokens.count == 3, let session = ptys.removeValue(forKey: parsed.tokens[2]) else {
                throw NeoYCoreError.invalidCommand("usage: pty close <id>")
            }
            if session.process.isRunning {
                session.process.terminate()
                usleep(100_000)
                if session.process.isRunning { kill(session.process.processIdentifier, SIGKILL) }
            }
            try? session.master.close()
            return "{\"ok\":true,\"id\":\"\(session.id)\"}"
        default:
            throw NeoYCoreError.invalidCommand("unknown PTY command '\(parsed.tokens[1])'")
        }
    }

    private struct LaunchOptions {
        var cwd = FileManager.default.homeDirectoryForCurrentUser.path
        var timeoutSeconds = 600
        var maxOutputBytes = 1_000_000
        var stdin: String?
        var environment: [String: String] = [:]
    }

    private func parseLaunchOptions(_ tokens: [String]) throws -> LaunchOptions {
        var result = LaunchOptions()
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case "--cwd":
                guard i + 1 < tokens.count else { throw NeoYCoreError.missingArgument("--cwd PATH") }
                result.cwd = Self.expand(tokens[i + 1]); i += 2
            case "--timeout":
                guard i + 1 < tokens.count, let value = Int(tokens[i + 1]) else { throw NeoYCoreError.missingArgument("--timeout SECONDS") }
                result.timeoutSeconds = min(max(value, 1), 1_800); i += 2
            case "--max-output":
                guard i + 1 < tokens.count, let value = Int(tokens[i + 1]) else { throw NeoYCoreError.missingArgument("--max-output BYTES") }
                result.maxOutputBytes = min(max(value, 1_024), 64_000_000); i += 2
            case "--stdin-base64":
                guard i + 1 < tokens.count, let data = Data(base64Encoded: tokens[i + 1]) else { throw NeoYCoreError.invalidCommand("invalid --stdin-base64") }
                result.stdin = String(decoding: data, as: UTF8.self); i += 2
            case "--env":
                guard i + 1 < tokens.count, let equal = tokens[i + 1].firstIndex(of: "=") else { throw NeoYCoreError.missingArgument("--env KEY=VALUE") }
                let pair = tokens[i + 1]
                result.environment[String(pair[..<equal])] = String(pair[pair.index(after: equal)...]); i += 2
            default:
                throw NeoYCoreError.invalidCommand("unexpected option '\(tokens[i])'")
            }
        }
        return result
    }

    private struct PTYOptions {
        var cwd = FileManager.default.homeDirectoryForCurrentUser.path
        var cols = 120
        var rows = 30
    }

    private func parsePTYOptions(_ tokens: [String]) throws -> PTYOptions {
        var result = PTYOptions()
        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case "--cwd":
                guard i + 1 < tokens.count else { throw NeoYCoreError.missingArgument("--cwd PATH") }
                result.cwd = Self.expand(tokens[i + 1]); i += 2
            case "--cols":
                guard i + 1 < tokens.count, let value = Int(tokens[i + 1]), (20...500).contains(value) else { throw NeoYCoreError.invalidCommand("invalid --cols") }
                result.cols = value; i += 2
            case "--rows":
                guard i + 1 < tokens.count, let value = Int(tokens[i + 1]), (5...200).contains(value) else { throw NeoYCoreError.invalidCommand("invalid --rows") }
                result.rows = value; i += 2
            default:
                throw NeoYCoreError.invalidCommand("unexpected PTY option '\(tokens[i])'")
            }
        }
        return result
    }

    private func startPTY(command: String, options: PTYOptions) throws -> String {
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(
            ws_row: UInt16(options.rows), ws_col: UInt16(options.cols),
            ws_xpixel: 0, ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw NeoYCoreError.operationFailed("openpty failed: \(String(cString: strerror(errno)))")
        }

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: options.cwd)
        process.environment = Self.mergedEnvironment(["TERM": "xterm-256color"])
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
        do {
            try process.run()
        } catch {
            try? masterHandle.close()
            try? slaveHandle.close()
            throw error
        }
        try? slaveHandle.close()

        let id = UUID().uuidString.lowercased()
        let session = PTYSession(
            id: id, process: process, master: masterHandle, command: command,
            cwd: options.cwd, cols: options.cols, rows: options.rows
        )
        ptys[id] = session
        return NeoYCoreJSON.encode(ptyStatus(session))
    }

    private func readPTY(_ session: PTYSession, maxBytes: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: maxBytes)
        let count = Darwin.read(session.master.fileDescriptor, &bytes, maxBytes)
        let data: Data
        if count > 0 { data = Data(bytes.prefix(Int(count))) }
        else { data = Data() }

        struct Result: Codable {
            let id: String
            let text: String
            let base64: String
            let bytes: Int
            let running: Bool
            let exitCode: Int32?
        }
        return NeoYCoreJSON.encode(Result(
            id: session.id,
            text: String(decoding: data, as: UTF8.self),
            base64: data.base64EncodedString(),
            bytes: data.count,
            running: session.process.isRunning,
            exitCode: session.process.isRunning ? nil : session.process.terminationStatus
        ))
    }

    private func resizePTY(_ session: PTYSession, cols: Int, rows: Int) throws {
        var window = winsize(
            ws_row: UInt16(rows), ws_col: UInt16(cols),
            ws_xpixel: 0, ws_ypixel: 0
        )
        guard ioctl(session.master.fileDescriptor, TIOCSWINSZ, &window) == 0 else {
            throw NeoYCoreError.operationFailed("PTY resize failed: \(String(cString: strerror(errno)))")
        }
        session.cols = cols
        session.rows = rows
        _ = kill(session.process.processIdentifier, SIGWINCH)
    }

    private func ptyStatus(_ session: PTYSession) -> NeoYPTYStatus {
        NeoYPTYStatus(
            id: session.id,
            pid: session.process.processIdentifier,
            running: session.process.isRunning,
            exitCode: session.process.isRunning ? nil : session.process.terminationStatus,
            command: session.command,
            cwd: session.cwd,
            cols: session.cols,
            rows: session.rows
        )
    }

    private func status(for job: BackgroundJob) -> NeoYBackgroundJobStatus {
        NeoYBackgroundJobStatus(
            id: job.id,
            pid: job.process.processIdentifier,
            running: job.process.isRunning,
            exitCode: job.process.isRunning ? nil : job.process.terminationStatus,
            startedAt: job.startedAt,
            command: job.command,
            cwd: job.cwd
        )
    }

    private static func runProcess(
        command: String, cwd: String, environment: [String: String],
        stdin: String?, timeoutSeconds: Int, maxOutputBytes: Int
    ) throws -> NeoYExecResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("neoy-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outURL = directory.appendingPathComponent("stdout")
        let errURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = mergedEnvironment(environment)
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let pipe = Pipe()
            process.standardInput = pipe
            try process.run()
            try? pipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try? pipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline { usleep(20_000) }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            usleep(100_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        try? out.synchronize()
        try? err.synchronize()
        let stdout = readBounded(outURL, maxBytes: maxOutputBytes)
        let stderr = readBounded(errURL, maxBytes: maxOutputBytes)
        return NeoYExecResult(
            exitCode: process.terminationStatus,
            signal: process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil,
            timedOut: timedOut,
            stdout: String(decoding: stdout.data, as: UTF8.self),
            stderr: String(decoding: stderr.data, as: UTF8.self),
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated
        )
    }

    private static func mergedEnvironment(_ override: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in override { environment[key] = value }
        return environment
    }

    private static func expand(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    private static func readBounded(_ url: URL, maxBytes: Int) -> (data: Data, truncated: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), false) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return (data, size > UInt64(maxBytes))
    }

    private static func tail(_ url: URL, maxBytes: Int) -> String {
        String(decoding: readBounded(url, maxBytes: maxBytes).data, as: UTF8.self)
    }

    private static func signalNumber(_ value: String) throws -> Int32 {
        switch value.uppercased() {
        case "INT": SIGINT
        case "TERM": SIGTERM
        case "KILL": SIGKILL
        case "HUP": SIGHUP
        case "WINCH": SIGWINCH
        default: throw NeoYCoreError.invalidCommand("unsupported signal '\(value)'")
        }
    }

    static let help = """
    mac.exec — privileged local-user execution
      run [--cwd PATH] [--timeout SECONDS] [--max-output BYTES] [--env KEY=VALUE] [--stdin-base64 DATA] -- <shell command>
      start [--cwd PATH] [--env KEY=VALUE] -- <shell command>
      jobs
      status <job-id>
      logs <job-id> [--max-bytes N]
      stop <job-id>
      pty start [--cwd PATH] [--cols N] [--rows N] -- <shell command>
      pty read <session-id> [--max-bytes N]
      pty write <session-id> -- <text>
      pty resize <session-id> <cols> <rows>
      pty signal <session-id> <INT|TERM|KILL|HUP|WINCH>
      pty close <session-id>
    Commands run with the macOS user that launched NeoY. PTY input is never written to NeoY logs.
    """
}

enum NeoYExecTools {
    static func tools(service: NeoYExecService) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "exec",
                description: "Core command execution, background jobs, and PTY sessions. Call with command='help' for authoritative grammar.",
                parameters: NeoYCoreJSON.string("CLI-like command; use 'help' for grammar")
            ) { arguments in
                try await service.execute(NeoYCoreJSON.command(from: arguments))
            }
        ]
    }
}
