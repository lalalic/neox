import Foundation

/// One independently versioned, signed Rust Core. The native host owns its
/// lifecycle, while the child alone owns shell/filesystem/PTY/job semantics.
/// Node Core is not an installation, recovery, probe, or runtime fallback.
enum NeoYManagedRustCoreRuntime {
    static var root: URL {
        NeoYPaths.supportDirectory.appendingPathComponent("core/rust", isDirectory: true)
    }
    static var packaged: URL {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("neoy-core-rust")
    }
    static func valid(_ binary: URL, files: FileManager = .default) -> Bool {
        files.isExecutableFile(atPath: binary.path) &&
        !binary.hasDirectoryPath && (try? files.attributesOfItem(atPath: binary.path)[.type] as? FileAttributeType) != .typeDirectory
    }
    static func active(in root: URL = root, files: FileManager = .default) -> URL? {
        let current = root.appendingPathComponent("current")
        guard let target = try? files.destinationOfSymbolicLink(atPath: current.path) else { return nil }
        let resolved = URL(fileURLWithPath: target, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        let versions = root.appendingPathComponent("versions", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(versions.path + "/"),
              !resolved.lastPathComponent.hasPrefix("."),
              valid(resolved.appendingPathComponent("neoy-core-rust"), files: files) else { return nil }
        return resolved.appendingPathComponent("neoy-core-rust")
    }
    static func selected(bundle: URL = packaged, root: URL = root) -> URL? {
        active(in: root) ?? (valid(bundle) ? bundle : nil)
    }
    static func version(of binary: URL) -> String? {
        guard valid(binary) else { return nil }
        // Never allow a stalled/corrupt candidate to block NeoY's main thread.
        // Capture stdout to a private file rather than a pipe that could fill
        // before the timeout watchdog runs.
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-rust-version-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: log.path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]),
              let file = try? FileHandle(forWritingTo: log) else { return nil }
        defer {
            try? file.close()
            try? FileManager.default.removeItem(at: log)
        }
        let task = Process()
        task.executableURL = binary
        task.arguments = ["--version"]
        task.standardOutput = file
        task.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }
        do { try task.run() } catch { return nil }
        if finished.wait(timeout: .now() + 3) == .timedOut {
            if task.isRunning { task.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut {
                kill(task.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            return nil
        }
        guard task.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber,
              size.intValue < 128,
              let data = try? Data(contentsOf: log) else { return nil }
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return validVersion(version) ? version : nil
    }
    static func validVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil
            && !version.contains("..")
    }
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        func fields(_ version: String) -> [Int]? {
            let components = version.split(separator: "-", maxSplits: 1)[0].split(separator: ".")
            let integers = components.compactMap { Int($0) }
            return integers.count == 3 ? integers : nil
        }
        guard let a = fields(lhs), let b = fields(rhs) else { return false }
        return a.lexicographicallyPrecedes(b)
    }
    static func installed(_ version: String, root: URL) -> URL {
        root.appendingPathComponent("versions/\(version)/neoy-core-rust")
    }
    @discardableResult
    static func install(source: URL, version: String, root: URL = root, files: FileManager = .default) throws -> URL {
        guard validVersion(version), valid(source, files: files) else {
            throw error(1, "Invalid Rust Core version or executable")
        }
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        try files.createDirectory(at: versions, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let destination = versions.appendingPathComponent(version, isDirectory: true)
        if files.fileExists(atPath: destination.path) {
            guard valid(destination.appendingPathComponent("neoy-core-rust"), files: files) else {
                throw error(2, "Installed Rust Core version is damaged")
            }
            // Immutable releases: a different binary must have a new version.
            // Never silently claim an upgrade when the existing bytes differ.
            let existing = try Data(contentsOf: destination.appendingPathComponent("neoy-core-rust"))
            let incoming = try Data(contentsOf: source)
            guard existing == incoming else {
                throw error(13, "A different Rust Core binary already uses this version")
            }
        } else {
            let staging = versions.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? files.removeItem(at: staging) }
            try files.createDirectory(at: staging, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let target = staging.appendingPathComponent("neoy-core-rust")
            try files.copyItem(at: source, to: target)
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            guard valid(target, files: files) else { throw error(3, "Staged Rust Core invalid") }
            try files.moveItem(at: staging, to: destination)
        }
        let current = root.appendingPathComponent("current")
        let next = root.appendingPathComponent(".current-\(UUID().uuidString)")
        try files.createSymbolicLink(at: next, withDestinationURL: destination)
        guard rename(next.path, current.path) == 0 else {
            let code = errno
            try? files.removeItem(at: next)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return destination.appendingPathComponent("neoy-core-rust")
    }
    static func bootstrapIfMissing(bundle: URL = packaged, root: URL = root,
                                   probe: (URL) -> Bool = probeMCP) throws {
        guard active(in: root) == nil else { return }
        guard let version = version(of: bundle), probe(bundle) else {
            throw error(4, "Signed bundle does not contain a healthy Rust Core seed")
        }
        let destination = installed(version, root: root)
        if FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path),
           (!valid(destination) || !probe(destination)) {
            try quarantine(version: version, root: root)
        }
        try install(source: bundle, version: version, root: root)
    }
    @discardableResult
    static func reconcileStartup(bundle: URL = packaged, root: URL = root,
                                 probe: (URL) -> Bool = probeMCP,
                                 version: (URL) -> String? = version(of:)) throws -> String {
        let previous = active(in: root)
        let existingVersion = previous?.deletingLastPathComponent().lastPathComponent
        let seedVersion = version(bundle)
        if let previous, let existingVersion, probe(previous) {
            if let seedVersion, isOlder(existingVersion, than: seedVersion), probe(bundle) {
                if FileManager.default.fileExists(atPath: installed(seedVersion, root: root).deletingLastPathComponent().path),
                   (!valid(installed(seedVersion, root: root)) || !probe(installed(seedVersion, root: root))) {
                    try quarantine(version: seedVersion, root: root)
                }
                try install(source: bundle, version: seedVersion, root: root)
                guard let selected = active(in: root), probe(selected) else {
                    try? rollback(to: existingVersion, root: root)
                    throw error(5, "Bundled Rust Core failed post-activation MCP check")
                }
                try existingVersion.write(to: root.appendingPathComponent("previous-version"),
                                          atomically: true, encoding: .utf8)
                return seedVersion
            }
            return existingVersion
        }
        if let previousVersion = try? String(contentsOf: root.appendingPathComponent("previous-version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), validVersion(previousVersion),
           let selected = try? rollback(to: previousVersion, root: root, probe: probe) {
            return selected
        }
        guard let seedVersion, probe(bundle) else { throw error(6, "No healthy Rust Core or signed bundle recovery seed") }
        let destination = installed(seedVersion, root: root)
        if FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path),
           (!valid(destination) || !probe(destination)) {
            try quarantine(version: seedVersion, root: root)
        }
        try install(source: bundle, version: seedVersion, root: root)
        guard let selected = active(in: root), probe(selected) else {
            throw error(7, "Recovered bundled Rust Core failed MCP probe")
        }
        if let existingVersion, existingVersion != seedVersion {
            try? existingVersion.write(to: root.appendingPathComponent("previous-version"),
                                       atomically: true, encoding: .utf8)
        }
        return seedVersion
    }
    @discardableResult
    static func rollback(to version: String, root: URL = root,
                         probe: (URL) -> Bool = probeMCP) throws -> String {
        guard validVersion(version) else { throw error(8, "Invalid rollback version") }
        let binary = installed(version, root: root)
        guard valid(binary), probe(binary) else { throw error(9, "Rollback Rust Core is unhealthy") }
        try install(source: binary, version: version, root: root)
        return version
    }
    static func rollbackPrevious(root: URL = root, probe: (URL) -> Bool = probeMCP) throws -> String {
        let last = root.appendingPathComponent("previous-version")
        let wanted = try String(contentsOf: last, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let current = active(in: root)?.deletingLastPathComponent().lastPathComponent
        let selected = try rollback(to: wanted, root: root, probe: probe)
        if let current, current != selected {
            try current.write(to: last, atomically: true, encoding: .utf8)
        }
        return selected
    }
    /// Only explicitly supplied, already signed Rust executables or the signed app seed.
    /// Never contacts npm, downloads arbitrary code, or falls back to Node.
    static func upgrade(_ requested: String, bundle: URL = packaged, root: URL = root,
                        probe: (URL) -> Bool = probeMCP,
                        signature: (URL) -> Bool = trustedSignature) throws -> String {
        let source: URL
        if requested == "bundled" { source = bundle }
        else {
            guard requested.hasPrefix("/") else { throw error(10, "Pass bundled or an absolute signed Rust binary path") }
            source = URL(fileURLWithPath: requested)
        }
        guard signature(source), let version = version(of: source), probe(source) else {
            throw error(11, "Rust Core upgrade must be a signed, healthy MCP executable")
        }
        let previous = active(in: root)?.deletingLastPathComponent().lastPathComponent
        let destination = installed(version, root: root)
        if FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path),
           (!valid(destination) || !probe(destination)) {
            try quarantine(version: version, root: root)
        }
        try install(source: source, version: version, root: root)
        guard let selected = active(in: root), probe(selected) else {
            if let previous { try? rollback(to: previous, root: root, probe: probe) }
            else { try? FileManager.default.removeItem(at: root.appendingPathComponent("current")) }
            throw error(12, "Activated Rust Core failed MCP health check")
        }
        if let previous, previous != version {
            try previous.write(to: root.appendingPathComponent("previous-version"), atomically: true, encoding: .utf8)
        }
        return version
    }
    static func trustedSignature(_ candidate: URL) -> Bool {
        guard valid(candidate) else { return false }
        // A valid signature on any executable is not enough: require the same
        // Developer Team as NeoY's signed app for independently supplied Core.
        func run(_ args: [String]) -> (Int32, String) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            task.arguments = args
            let output = Pipe()
            task.standardError = output
            task.standardOutput = output
            do { try task.run() } catch { return (-1, "") }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(decoding: bytes, as: UTF8.self))
        }
        guard run(["--verify", "--strict", candidate.path]).0 == 0,
              let host = Bundle.main.executableURL else { return false }
        let team = run(["-dv", "--verbose=2", host.path]).1
        let child = run(["-dv", "--verbose=2", candidate.path]).1
        let marker = "TeamIdentifier="
        guard let hostTeam = team.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else { return false }
        return child.split(separator: "\n").contains(hostTeam)
    }
    /// Real Rust MCP handshake, using a disposable Core data directory. No Node or JS probe.
    static func probeMCP(_ executable: URL) -> Bool {
        guard valid(executable) else { return false }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("neoy-rust-probe-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true) } catch { return false }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let task = Process()
        task.executableURL = executable
        task.environment = ProcessInfo.processInfo.environment.merging(
            NeoYBundledRuntime.coreEnvironment.merging(["NEO_CORE_DATA_DIR": scratch.path]) { _, newer in newer }
        ) { _, newer in newer }
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        let message = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}

        """
        input.fileHandleForWriting.write(Data(message.utf8))
        try? input.fileHandleForWriting.close()
        // A stdio MCP child may keep its background workers alive after
        // initialization. Verify BOTH replies rather than waiting for stdout
        // EOF or a graceful process exit, which can deadlock startup probes.
        let done = DispatchSemaphore(value: 0)
        let reader = RustProbeOutput()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if reader.consume(chunk) { done.signal(); break }
            }
        }
        let ready = done.wait(timeout: .now() + 8) == .success
        if task.isRunning { task.terminate() }
        // Reap the probe promptly without allowing a stuck child to block app
        // startup. Never leave defunct probe processes behind.
        let reaped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            task.waitUntilExit()
            reaped.signal()
        }
        if reaped.wait(timeout: .now() + 2) == .timedOut {
            kill(task.processIdentifier, SIGKILL)
            _ = reaped.wait(timeout: .now() + 2)
        }
        return ready
    }
    private static func quarantine(version: String, root: URL) throws {
        let source = root.appendingPathComponent("versions/\(version)")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("versions/.damaged-\(version)-\(UUID().uuidString)"))
    }
    private static func error(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "NeoYRustCore", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

private final class RustProbeOutput: @unchecked Sendable {
    private var remaining = Data()
    private var hasInitialize = false
    private var hasTools = false

    func consume(_ chunk: Data) -> Bool {
        remaining.append(chunk)
        // Bound response parsing and avoid processing arbitrary protocol data.
        guard remaining.count <= 131_072 else { return false }
        while let newline = remaining.firstIndex(of: 10) {
            let line = Data(remaining[..<newline])
            remaining.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = row["id"] as? Int,
                  let result = row["result"] as? [String: Any] else { continue }
            if id == 1, let info = result["serverInfo"] as? [String: Any],
               info["name"] as? String == "neo-core-tools" { hasInitialize = true }
            if id == 2, let inventory = result["tools"] as? [[String: Any]] {
                let names = Set(inventory.compactMap { $0["name"] as? String })
                if names.contains("shell") && names.contains("fs") { hasTools = true }
            }
            if hasInitialize && hasTools { return true }
        }
        return false
    }
}
