import Foundation

/// Independently versioned Core runtime. The signed bundle is only a bootstrap/recovery source.
enum NeoYManagedCoreRuntime {
    static var root: URL {
        NeoYPaths.supportDirectory.appendingPathComponent("runtimes/core", isDirectory: true)
    }
    static func valid(_ path: URL, files: FileManager = .default) -> Bool {
        files.isReadableFile(atPath: path.appendingPathComponent("package.json").path) &&
        files.isReadableFile(atPath: path.appendingPathComponent("src/core/tools/index.mjs").path)
    }
    static func active(in root: URL = root, files: FileManager = .default) -> URL? {
        let current = root.appendingPathComponent("current")
        guard let target = try? files.destinationOfSymbolicLink(atPath: current.path) else { return nil }
        let resolved = URL(fileURLWithPath: target, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath()
        let versions = root.appendingPathComponent("versions", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(versions.path + "/"), valid(resolved, files: files) else { return nil }
        return resolved
    }
    static func selected(bundle: URL = NeoYBundledRuntime.packagedRuntimeURL, root: URL = root) -> URL {
        active(in: root) ?? bundle
    }
    /// Activate only after validation. A previous active version remains as rollback target.
    @discardableResult
    static func install(source: URL, version: String, root: URL = root, files: FileManager = .default) throws -> URL {
        guard version.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil,
              !version.contains(".."), valid(source, files: files) else {
            throw NSError(domain: "NeoYCore", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid Core source or version"])
        }
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        try files.createDirectory(at: versions, withIntermediateDirectories: true)
        let destination = versions.appendingPathComponent(version, isDirectory: true)
        if files.fileExists(atPath: destination.path) {
            guard valid(destination, files: files) else { throw NSError(domain: "NeoYCore", code: 2, userInfo: [NSLocalizedDescriptionKey: "corrupt installed Core version"]) }
        } else {
            let staging = versions.appendingPathComponent(".staging-\(UUID().uuidString)")
            defer { try? files.removeItem(at: staging) }
            try files.copyItem(at: source, to: staging)
            guard valid(staging, files: files) else { throw NSError(domain: "NeoYCore", code: 3, userInfo: [NSLocalizedDescriptionKey: "staged Core failed validation"]) }
            try files.moveItem(at: staging, to: destination)
        }
        let current = root.appendingPathComponent("current")
        let temp = root.appendingPathComponent(".current-\(UUID().uuidString)")
        try files.createSymbolicLink(at: temp, withDestinationURL: destination)
        // POSIX rename atomically replaces a symlink (FileManager.moveItem does not).
        guard rename(temp.path, current.path) == 0 else {
            let code = errno
            try? files.removeItem(at: temp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return destination
    }
    static func rollback(to version: String, root: URL = root) throws {
        let source = root.appendingPathComponent("versions/\(version)", isDirectory: true)
        guard valid(source) else { throw NSError(domain: "NeoYCore", code: 4, userInfo: [NSLocalizedDescriptionKey: "rollback version not installed"]) }
        try install(source: source, version: version, root: root)
    }
    /// Upgrade from a separately acquired, unpacked and verified @lalalic/neo package.
    /// A candidate must pass a Node syntax check before atomically becoming active.
    static func upgrade(source: URL, version: String, root: URL = root, node: URL) throws {
        guard valid(source) else { throw NSError(domain: "NeoYCore", code: 5, userInfo: [NSLocalizedDescriptionKey: "invalid upgrade package"]) }
        let check = Process()
        check.executableURL = node
        check.arguments = ["--check", source.appendingPathComponent("src/core/tools/index.mjs").path]
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw NSError(domain: "NeoYCore", code: 6, userInfo: [NSLocalizedDescriptionKey: "candidate Core syntax validation failed"]) }
        try install(source: source, version: version, root: root)
    }
    static var nodeExecutable: URL? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }
    static func isOlder(_ candidate: String, than active: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let text = version.split(separator: "-", maxSplits: 1)[0]
            let fields = text.split(separator: ".")
            guard fields.count == 3 else { return nil }
            let digits = fields.compactMap { Int($0) }
            return digits.count == 3 ? digits : nil
        }
        guard let lhs = parts(candidate), let rhs = parts(active) else { return false }
        for index in 0..<3 {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] }
        }
        return false
    }
    /// Accept an npm version/tag or a local verified .tgz release artifact.
    static func registryUpgrade(version requested: String, root: URL = root) throws -> String {
        let local = requested.hasPrefix("/") && requested.hasSuffix(".tgz")
        let validVersion = requested == "latest" ||
            requested.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$", options: .regularExpression) != nil
        guard local || validVersion else {
            throw NSError(domain: "NeoYCore", code: 7, userInfo: [NSLocalizedDescriptionKey: "Enter latest, a version, or an absolute .tgz path"])
        }
        if local && !FileManager.default.isReadableFile(atPath: requested) {
            throw NSError(domain: "NeoYCore", code: 7, userInfo: [NSLocalizedDescriptionKey: "Core release archive not found"])
        }
        guard let npm = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let node = nodeExecutable else {
            throw NSError(domain: "NeoYCore", code: 8, userInfo: [NSLocalizedDescriptionKey: "Node and npm are required"])
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("neoy-core-upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: npm)
        task.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        task.arguments = ["install", "--prefix", staging.path, "--ignore-scripts", "--no-audit", "--no-fund", "--save=false", local ? requested : "@lalalic/neo@\(requested)"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let log = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "NeoYCore", code: 9, userInfo: [NSLocalizedDescriptionKey: "Core download failed: \(String(decoding: log, as: UTF8.self).suffix(400))"])
        }
        let source = staging.appendingPathComponent("node_modules/@lalalic/neo")
        guard valid(source) else { throw NSError(domain: "NeoYCore", code: 10, userInfo: [NSLocalizedDescriptionKey: "Downloaded Core has no entrypoint"]) }
        let metadata = try Data(contentsOf: source.appendingPathComponent("package.json"))
        let info = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        guard info?["name"] as? String == "@lalalic/neo", let version = info?["version"] as? String,
              local || requested == "latest" || version == requested else {
            throw NSError(domain: "NeoYCore", code: 11, userInfo: [NSLocalizedDescriptionKey: "Downloaded Core identity/version mismatch"])
        }
        let probe = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("core-mcp-probe.mjs")
        guard FileManager.default.isReadableFile(atPath: probe.path) else {
            throw NSError(domain: "NeoYCore", code: 12, userInfo: [NSLocalizedDescriptionKey: "Core MCP probe missing from NeoY.app"])
        }
        let health = Process()
        health.executableURL = node
        health.arguments = [probe.path, source.appendingPathComponent("src/core/tools/index.mjs").path]
        try health.run()
        health.waitUntilExit()
        guard health.terminationStatus == 0 else {
            throw NSError(domain: "NeoYCore", code: 13, userInfo: [NSLocalizedDescriptionKey: "Candidate Core failed MCP initialization/tools/list; existing Core preserved"])
        }
        let previous = active(in: root)?.lastPathComponent
        if let previous, isOlder(version, than: previous) {
            throw NSError(domain: "NeoYCore", code: 15, userInfo: [NSLocalizedDescriptionKey: "Refusing Core downgrade \(previous) → \(version); use Rollback for an installed previous version"])
        }
        try install(source: source, version: version, root: root)
        // Probe the *activated* copy as well; restore last known good on failure.
        let activated = Process()
        activated.executableURL = node
        activated.arguments = [probe.path, root.appendingPathComponent("current/src/core/tools/index.mjs").path]
        do {
            try activated.run()
            activated.waitUntilExit()
            guard activated.terminationStatus == 0 else { throw NSError(domain: "NeoYCore", code: 16, userInfo: [NSLocalizedDescriptionKey: "Activated Core failed MCP probe"]) }
        } catch {
            if let previous { try? rollback(to: previous, root: root) }
            else { try? FileManager.default.removeItem(at: root.appendingPathComponent("current")) }
            throw error
        }
        if let previous, previous != version {
            try? previous.write(to: root.appendingPathComponent("previous-version"), atomically: true, encoding: .utf8)
        }
        return version
    }
    static func rollbackPrevious(root: URL = root) throws -> String {
        let previous = try String(contentsOf: root.appendingPathComponent("previous-version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty else { throw NSError(domain: "NeoYCore", code: 14, userInfo: [NSLocalizedDescriptionKey: "No prior Core version"])}
        let current = active(in: root)?.lastPathComponent
        try rollback(to: previous, root: root)
        if let current, current != previous {
            try? current.write(to: root.appendingPathComponent("previous-version"), atomically: true, encoding: .utf8)
        }
        return previous
    }
    static func bootstrapIfMissing(bundle: URL = NeoYBundledRuntime.packagedRuntimeURL, root: URL = root) throws {
        guard active(in: root) == nil, valid(bundle) else { return }
        let data = try Data(contentsOf: bundle.appendingPathComponent("package.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let version = json?["version"] as? String else { return }
        try install(source: bundle, version: version, root: root)
    }
}
