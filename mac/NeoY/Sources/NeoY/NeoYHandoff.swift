import Foundation
import dnssd

/// Native NeoX handoff receiver. It owns no TCP listener: /agent routes are
/// registered on NeoY's single 6767 HTTP server.
final class NativeNeoYPhoneHandoffReceiver: NeoYPhoneHandoffReceiver, @unchecked Sendable {
    private struct State {
        var isRunning = false
        var lastHandoffAt: Date?
        var lastError: String?
    }

    private let targetStore: NeoXPhoneTargetStore
    private let inbox: URL
    private let lock = NSLock()
    private var state = State()
    private var bonjourRef: DNSServiceRef?

    init(targetStore: NeoXPhoneTargetStore, inbox: URL? = nil) {
        self.targetStore = targetStore
        self.inbox = inbox ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".neoy/inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.inbox, withIntermediateDirectories: true)
    }

    @MainActor
    func registerRoutes(on server: MCPServer) {
        server.registerHTTPRoute(method: "POST", path: "/agent") { [weak self] _, _, _, body in
            guard let self else { return HTTPRouteResponse(status: 503) }
            return await self.receiveHandoff(body)
        }
        for path in ["/agent/next", "/agent/peek"] {
            server.registerHTTPRoute(method: "GET", path: path) { [weak self] _, _, query, _ in
                guard let self else { return HTTPRouteResponse(status: 503) }
                return await self.readHandoff(path: path, query: query)
            }
        }
    }

    func start() throws {
        updateState {
            $0.isRunning = true
            $0.lastError = nil
        }
        publishBonjour()
    }

    func stop() {
        let ref: DNSServiceRef?
        lock.lock()
        state.isRunning = false
        ref = bonjourRef
        bonjourRef = nil
        lock.unlock()
        if let ref { DNSServiceRefDeallocate(ref) }
    }

    var isRunning: Bool {
        readState().isRunning
    }

    func statusJSON() -> String {
        let snapshot = readState()
        return NeoXPhoneClient.jsonString([
            "service": "_neoy._tcp",
            "path": "/agent",
            "port": Int(NeoYDeploymentSettingsStore.load().mcpPort),
            "inbox": inbox.path,
            "running": snapshot.isRunning,
            "pending": pendingFiles().count,
            "last_handoff_at": snapshot.lastHandoffAt.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? NSNull(),
            "error": snapshot.lastError ?? NSNull()
        ])
    }

    private func receiveHandoff(_ body: Data?) async -> HTTPRouteResponse {
        guard let body, body.count >= 8 else {
            return HTTPRouteResponse(status: 400, body: Data("handoff body is required".utf8), contentType: "text/plain")
        }
        do {
            let name = "\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000)).txt"
            try body.write(to: inbox.appendingPathComponent(name), options: .atomic)
            updateState {
                $0.lastHandoffAt = Date()
                $0.lastError = nil
            }
            setPhoneTarget(from: body)
            return HTTPRouteResponse(status: 200, body: Data("ok".utf8), contentType: "text/plain")
        } catch {
            updateState { $0.lastError = error.localizedDescription }
            return HTTPRouteResponse(status: 500, body: Data("Internal Server Error".utf8), contentType: "text/plain")
        }
    }

    private func readHandoff(path: String, query: [String: String]) async -> HTTPRouteResponse {
        let timeout = min(max(Double(query["timeout"] ?? "0") ?? 0, 0), 30)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let file = pendingFiles().first {
                do {
                    let message = try Data(contentsOf: file)
                    if path == "/agent/next" {
                        try FileManager.default.removeItem(at: file)
                    }
                    return HTTPRouteResponse(
                        status: 200,
                        body: message,
                        contentType: "text/plain; charset=utf-8"
                    )
                } catch {
                    updateState { $0.lastError = error.localizedDescription }
                    return HTTPRouteResponse(status: 500)
                }
            }
            if Date() >= deadline {
                return HTTPRouteResponse(status: 204)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func pendingFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil, options: []
        ))?
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private func setPhoneTarget(from message: Data) {
        guard let text = String(data: message, encoding: .utf8),
              let range = text.range(
                of: #"https?://[^\s,;)]+"#,
                options: .regularExpression
              ),
              let url = URL(string: String(text[range])) else { return }
        targetStore.set(.http(url), name: url.host(percentEncoded: false), replaceBonjour: true)
    }

    private func updateState(_ body: (inout State) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }

    private func readState() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func publishBonjour() {
        var txt = Data()
        for item in [
            "path=/agent",
            "host=\(Self.hostName)",
            "port=\(NeoYDeploymentSettingsStore.load().mcpPort)",
            "ip=\(Self.lanIPv4 ?? "127.0.0.1")"
        ] {
            let data = Data(item.utf8)
            guard data.count <= 255 else { continue }
            txt.append(UInt8(data.count))
            txt.append(data)
        }

        var ref: DNSServiceRef?
        let result: DNSServiceErrorType = txt.withUnsafeBytes { raw in
            DNSServiceRegister(
                &ref, 0, 0, Self.hostName, "_neoy._tcp", nil, nil,
                NeoYDeploymentSettingsStore.load().mcpPort.bigEndian,
                UInt16(raw.count), raw.baseAddress, nil, nil
            )
        }
        guard result == kDNSServiceErr_NoError, let ref else {
            lock.lock()
            state.lastError = "DNS-SD registration failed: \(result)"
            lock.unlock()
            return
        }
        let queue = DispatchQueue(label: "neoy-handoff-bonjour")
        guard DNSServiceSetDispatchQueue(ref, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(ref)
            return
        }
        lock.lock()
        bonjourRef = ref
        lock.unlock()
    }

    private static var hostName: String {
        let raw = ProcessInfo.processInfo.hostName
        return raw.split(separator: ".").first.map(String.init) ?? raw
    }

    private static var lanIPv4: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var current = ifaddr
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let interface = item.pointee.ifa_addr,
                  interface.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface, socklen_t(interface.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let value = String(cString: host)
            if value != "127.0.0.1" {
                address = value
                if name == "en0" { break }
            }
        }
        return address
    }
}
