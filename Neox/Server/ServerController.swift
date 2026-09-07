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

    private var server: MCPServer?
    private static let logLimit = 120

    private init() {
        photosStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Idempotent — safe to call on every foreground activation.
    func ensureRunning() {
        guard server == nil else { return }
        start()
    }

    func start() {
        guard server == nil else { return }
        state = .starting

        let server = MCPServer(name: "neox", port: port, bonjourName: "neox")
        try? FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        server.setStaticFileRoot(exportsDir)
        server.register(tools: MediaTools.tools(exportsDir: exportsDir))
        server.register(tools: VisionMediaTools.tools(exportsDir: exportsDir))
        server.register(
            name: "clear_exports",
            description: "Delete all files previously exported by media.export from the /files/ serving directory. Call this after finishing downloads to free space on the phone.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any]]
        ) { [weak self] _ in
            guard let self else { return "Error: server deallocated" }
            return await self.clearExports()
        }
        registeredTools = server.toolNames
        server.onRequest = { [weak self] line in
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
            appendLog("exports dir served at /files/: \(exportsDir.path)")
        } catch {
            state = .failed(error.localizedDescription)
            appendLog("start failed: \(error.localizedDescription)")
        }
    }

    func requestPhotosAccess() {
        Task {
            let status = await MediaTools.requestAccess()
            photosStatus = status
            appendLog("photos access: \(describe(status))")
        }
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
