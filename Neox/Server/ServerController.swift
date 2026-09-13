import Foundation
import Photos

/// Owns the MCP server lifecycle and wires the tool surface.
///
/// Exports directory contents are served at `http://<phone>:9223/files/<name>`
/// with HTTP Range support, so desktop agents stream multi-GB videos off the
/// phone without the app ever holding media bytes in memory.
@MainActor
final class ServerController: ObservableObject {
    static let shared = ServerController()

    enum State: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    /// Directory served at `/files/` — media.export writes here.
    let exportsDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("exports", isDirectory: true)

    @Published private(set) var state: State = .idle
    @Published private(set) var port: UInt16 = 9223
    @Published private(set) var logLines: [String] = []
    @Published private(set) var registeredTools: [String] = []
    @Published private(set) var photosStatus: PHAuthorizationStatus
    @Published private(set) var transaction: PhoneTransactionSnapshot?
    /// Desktop agent bridges ("Neoy") discovered on the LAN (`_neoy._tcp`).
    @Published private(set) var discoveredBridges: [AgentBridgeDiscovery.Entry] = []
    /// User's preferred bridge instance (persisted); nil = first discovered.
    @Published var preferredBridge: String? {
        didSet { UserDefaults.standard.set(preferredBridge, forKey: AgentBridge.preferredKey) }
    }
    /// Device capability probe result (nil until the startup probe finishes).
    @Published private(set) var caps: VisionCaps.Summary?

    /// Remote UI automation for agent-driven self-testing:
    /// `agent.pilot` (snapshot/tap/type/…) + `agent.demo` (spotlight/caption/TTS).
    let agentKit = AppAgentToolProvider()

    private var server: MCPServer?
    private var bridgeBrowser: AgentBridgeDiscovery?
    private let transactionCoordinator = PhoneTransactionCoordinator()
    private static let logLimit = 120

    private init() {
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        preferredBridge = UserDefaults.standard.string(forKey: AgentBridge.preferredKey)
    }

    /// Idempotent — safe to call on every foreground activation.
    ///
    /// iOS kills sockets while the app is backgrounded, sometimes without the
    /// NWListener ever reporting `.failed` (log shows "defunct connection").
    /// The old `guard server == nil` left a dead listener bound forever, so
    /// foregrounding now always tears down and re-binds. Rebinding is cheap
    /// and the app has no long-lived client connections to preserve.
    ///
    /// The Bonjour browser gets the same treatment: iOS suspends mDNS while
    /// backgrounded and NWBrowser doesn't always recover, so we tear it down
    /// and restart on every foreground. This is also what lets late-joining
    /// bridges appear — a fresh browse immediately sees everything on the LAN.
    func ensureRunning() {
        if let server {
            server.stop()
            self.server = nil
        }
        start()
        restartBridgeDiscovery()
    }

    /// Tear down and re-create the Bonjour browser. Called on every
    /// foreground so stale backgrounded browsers don't linger, and newly
    /// started bridges are discovered promptly.
    private func restartBridgeDiscovery() {
        bridgeBrowser?.stop()
        bridgeBrowser = nil
        discoveredBridges = []
        startBridgeDiscovery()
    }

    /// Keep a live Bonjour browse running for the handoff bridge — the status
    /// screen lists what's out there, and AgentBridge.handoff resolves fast
    /// because macOS/iOS cache mDNS answers seen recently.
    private func startBridgeDiscovery() {
        guard bridgeBrowser == nil else { return }
        let browser = AgentBridgeDiscovery()
        bridgeBrowser = browser
        browser.start()
        Task { [weak self] in
            for await entries in browser.entries() {
                guard let self else { return }
                self.discoveredBridges = entries
            }
        }
    }

    func start() {
        guard server == nil else { return }
        state = .starting

        let server = MCPServer(name: "neox", port: port, bonjourName: "neox")
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        server.setStaticFileRoot(exportsDir)
        server.register(tools: MediaTools.tools(exportsDir: exportsDir))
        server.register(tools: PhoneTransactionTools.tools())
        server.register(tools: agentKit.tools)
        server.register(tools: DebugTools.tools())
        server.register(
            name: "media.clear",
            description: "Delete all files previously exported by media.export from the /files/ serving directory. Call this after finishing downloads to free space on the phone.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]]
        ) { [weak self] _ in
            guard let self else { return "Error: server deallocated" }
            return await self.clearExports()
        }
        registeredTools = server.toolNames
        server.onRequest = { [weak self] line in
            // Raw request lines ("POST /mcp") are noise — the onToolCall line
            // (with the actual tool name) is what matters. Files requests
            // still get logged since they have no tool-call counterpart.
            guard line.contains("/files/") else { return }
            Task { @MainActor [weak self] in self?.appendLog(line) }
        }
        server.onToolCall = { [weak self] name, arguments in
            Task { @MainActor [weak self] in self?.appendLog("▸ \(name)(\(arguments))") }
        }
        server.onLog = { [weak self] message in
            Task { @MainActor [weak self] in self?.appendLog(message) }
        }
        do {
            try server.start()
            self.server = server
            state = .running
            appendLog("neox listening on 0.0.0.0:\(port)")
            // Probe device caps (fast, off-main), then register the
            // Vision/Speech tools this hardware actually supports.
            // Identity guard: the server may have been re-created (foreground
            // restart) by the time the probe finishes.
            Task { @MainActor [weak self] in
                let caps = await withCheckedContinuation { (cont: CheckedContinuation<VisionCaps.Summary, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: VisionCaps.probe())
                    }
                }
                guard let self, self.server === server else { return }
                let tools = VisionMediaTools.tools(exportsDir: self.exportsDir)
                if !tools.isEmpty { server.register(tools: tools) }
                self.registeredTools = server.toolNames
                self.caps = caps
                self.appendLog("caps: classify \(caps.classify ? "✓" : "✗") · ocr \(caps.ocr ? "✓" : "✗") · "
                             + "faces \(caps.faces ? "✓" : "✗") · speech \(caps.speech ? "✓" : "✗") · "
                             + "tools \(server.toolNames.count)")
            }
        } catch {
            state = .failed(error.localizedDescription)
            appendLog("start failed: \(error.localizedDescription)")
        }
    }

    /// Ask the user for Photos access; updates state and returns the result.
    @discardableResult
    func requestPhotosAccess() async -> PHAuthorizationStatus {
        let status = await MediaTools.requestAccess()
        photosStatus = status
        appendLog("photos access: \(describe(status))")
        return status
    }

    func startTransaction(_ args: JSONValue) -> String {
        let label = PhoneTransactionTools.displayText(
            MediaTools.str(args, "label") ?? "",
            fallback: "Desktop workflow"
        )
        let reason = MediaTools.str(args, "reason").map {
            PhoneTransactionTools.displayText($0, fallback: "Desktop workflow")
        }
        let timeoutMinutes = min(max(MediaTools.intOpt(args, "timeout_minutes") ?? 30, 1), 240)

        guard let transaction = transactionCoordinator.start(
            label: label,
            reason: reason,
            timeoutMinutes: timeoutMinutes
        ) else {
            return "Error: phone transaction already active"
        }

        self.transaction = transaction
        appendLog("phone transaction started: \(transaction.id.uuidString)")
        return PhoneTransactionTools.startedJSON(transaction)
    }

    func endTransaction(_ args: JSONValue) -> String {
        guard let idText = MediaTools.str(args, "transaction_id"),
              let id = UUID(uuidString: idText) else {
            return "Error: 'transaction_id' required"
        }
        guard let outcome = PhoneTransactionTools.outcome(MediaTools.str(args, "outcome")) else {
            return "Error: outcome must be completed, failed, or cancelled"
        }

        let result = transactionCoordinator.end(id: id, outcome: outcome)
        switch result {
        case .released(let transaction), .alreadyReleased(let transaction):
            self.transaction = transaction
            appendLog("phone transaction \(transaction.state): \(transaction.id.uuidString)")
            return PhoneTransactionTools.endedJSON(transaction, alreadyReleased: result.isAlreadyReleased)
        case .mismatched(let transaction):
            if let transaction {
                self.transaction = transaction
            }
            return "Error: transaction_id mismatch"
        case .notFound:
            return "Error: no active phone transaction"
        }
    }

    func refreshTransaction(at now: Date = .now) {
        _ = transactionCoordinator.refresh(at: now)
        transaction = transactionCoordinator.current
    }

    func dismissReleasedTransaction() {
        guard transaction?.state != .active else { return }
        transaction = nil
        transactionCoordinator.dismissReleased()
    }

    /// Delete all exported media from the /files/ serving directory.
    @discardableResult
    func clearExports() -> String {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: exportsDir, includingPropertiesForKeys: nil) else {
            appendLog("exports clear failed")
            return "Error: could not read exports directory"
        }
        var freed: Int64 = 0
        for entry in entries {
            freed += (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            try? fm.removeItem(at: entry)
        }
        let message = "cleared \(entries.count) files, freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
        appendLog("exports \(message)")
        return message
    }

    var mcpURL: String {
        if let ip = Self.lanIPAddress() {
            return "http://\(ip):\(port)/mcp"
        }
        return "http://<phone-ip>:\(port)/mcp"
    }

    /// Primary IPv4 of the en0 interface (WiFi), nil when unavailable.
    static func lanIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = pointer?.pointee.ifa_next }
            guard let interface = current.pointee.ifa_addr,
                  current.pointee.ifa_name.flatMap({ String(cString: $0) }) == "en0",
                  interface.pointee.sa_family == UInt8(AF_INET) else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(interface, socklen_t(interface.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
            }
        }
        return address
    }

    // MARK: - Private

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("[\(formatter.string(from: Date()))] \(line)")
        if logLines.count > Self.logLimit {
            logLines.removeFirst(logLines.count - Self.logLimit)
        }
    }

    private func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown"
        }
    }
}
