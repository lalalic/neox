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
    /// Desktop agent bridges ("Neoy") discovered on the LAN (`_neoy._tcp`).
    @Published private(set) var discoveredBridges: [AgentBridgeDiscovery.Entry] = []
    /// User's preferred bridge instance (persisted); nil = first discovered.
    @Published var preferredBridge: String? {
        didSet { UserDefaults.standard.set(preferredBridge, forKey: AgentBridge.preferredKey) }
    }

    /// Remote UI automation for agent-driven self-testing:
    /// `agent.pilot` (snapshot/tap/type/…) + `agent.demo` (spotlight/caption/TTS).
    let agentKit = AppAgentToolProvider()

    private var server: MCPServer?
    private var bridgeBrowser: AgentBridgeDiscovery?
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
        server.register(tools: VisionMediaTools.tools(exportsDir: exportsDir))
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
            appendLog("listening on 0.0.0.0:\(port) · bonjour neox._mcp._tcp")
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
