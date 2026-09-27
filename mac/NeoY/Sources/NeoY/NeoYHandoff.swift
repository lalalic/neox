import Foundation
import Network
import dnssd

/// Native replacement for the Python `_neoy._tcp` handoff bridge.
///
/// Compatibility contract: `POST /agent` with `text/plain` returns HTTP 200;
/// durable consumers may consume FIFO records with `GET /agent/next?timeout=`
/// or inspect them with `/agent/peek`. Messages remain under `~/.neoy/inbox`.
final class NativeNeoYPhoneHandoffReceiver: NeoYPhoneHandoffReceiver, @unchecked Sendable {
    static let port: UInt16 = 8686

    private struct State {
        var isRunning = false
        var lastHandoffAt: Date?
        var lastError: String?
    }

    private let targetStore: NeoXPhoneTargetStore
    private let inbox: URL
    private let queue = DispatchQueue(label: "neoy-handoff-http", qos: .userInitiated)
    private let bonjourQueue = DispatchQueue(label: "neoy-handoff-bonjour")
    private let lock = NSLock()
    private var state = State()
    private var listener: NWListener?
    private var bonjourRef: DNSServiceRef?

    init(targetStore: NeoXPhoneTargetStore, inbox: URL? = nil) {
        self.targetStore = targetStore
        self.inbox = inbox ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".neoy/inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.inbox, withIntermediateDirectories: true)
    }

    func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateState { value in
                    value.isRunning = true
                    value.lastError = nil
                }
            case .waiting(let error):
                self.updateState { $0.lastError = error.localizedDescription }
            case .failed(let error):
                self.updateState { value in
                    value.isRunning = false
                    value.lastError = error.localizedDescription
                }
            case .cancelled:
                self.updateState { $0.isRunning = false }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    Task {
                        await self.serve(connection)
                    }
                case .failed, .cancelled:
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        self.listener = listener
        publishBonjour()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        bonjourQueue.sync {
            lock.lock()
            let ref = bonjourRef
            bonjourRef = nil
            lock.unlock()
            if let ref { DNSServiceRefDeallocate(ref) }
        }
        updateState { $0.isRunning = false }
    }

    func statusJSON() -> String {
        let snapshot = readState()
        return [
            "service": "_neoy._tcp",
            "path": "/agent",
            "port": Int(Self.port),
            "inbox": inbox.path,
            "running": snapshot.isRunning,
            "pending": pendingFiles().count,
            "last_handoff_at": snapshot.lastHandoffAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "error": snapshot.lastError ?? NSNull(),
        ].sortedJSONString
    }

    private func publishBonjour() {
        bonjourQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyPublished = self.bonjourRef != nil
            self.lock.unlock()
            guard !alreadyPublished else { return }

            var txt = Data()
            for item in [
                "path=/agent",
                "host=\(Self.hostName)",
                "port=\(Self.port)",
                "ip=\(Self.lanIPv4 ?? "127.0.0.1")",
            ] {
                let data = Data(item.utf8)
                guard data.count <= 255 else { continue }
                txt.append(UInt8(data.count))
                txt.append(data)
            }

            var ref: DNSServiceRef?
            let result: DNSServiceErrorType = txt.withUnsafeBytes { raw in
                DNSServiceRegister(
                    &ref,
                    0,
                    0,
                    Self.hostName,
                    "_neoy._tcp",
                    nil,
                    nil,
                    Self.port.bigEndian,
                    UInt16(raw.count),
                    raw.baseAddress,
                    nil,
                    nil
                )
            }
            guard result == kDNSServiceErr_NoError, let ref else {
                self.updateState { $0.lastError = "DNS-SD registration failed: \(result)" }
                return
            }
            let queueResult = DNSServiceSetDispatchQueue(ref, self.bonjourQueue)
            guard queueResult == kDNSServiceErr_NoError else {
                DNSServiceRefDeallocate(ref)
                self.updateState { $0.lastError = "DNS-SD queue setup failed: \(queueResult)" }
                return
            }
            self.lock.lock()
            self.bonjourRef = ref
            self.lock.unlock()
        }
    }

    private func serve(_ connection: NWConnection) async {
        do {
            var buffered = Data()
            while buffered.range(of: Data("\r\n\r\n".utf8)) == nil {
                let chunk = try await receive(connection)
                guard !chunk.isEmpty else {
                    connection.cancel()
                    return
                }
                buffered.append(chunk)
            }
            guard let request = Request(buffered) else {
                send(connection, status: 400, body: Data("Bad Request".utf8), contentType: "text/plain")
                return
            }
            var body = request.body
            if let length = request.headers["content-length"], let length = Int(length), body.count < length {
                while body.count < length {
                    let chunk = try await receive(connection)
                    guard !chunk.isEmpty else { break }
                    body.append(chunk)
                }
            }

            switch (request.method, request.path) {
            case ("POST", "/agent"):
                if body.count >= 8 {
                    let name = "\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000)).txt"
                    try body.write(to: inbox.appendingPathComponent(name), options: .atomic)
                    updateState { $0.lastHandoffAt = Date() }
                    setPhoneTarget(from: body)
                }
                send(connection, status: 200, body: Data("ok".utf8), contentType: "text/plain")

            case ("GET", "/agent/next"), ("GET", "/agent/peek"):
                let timeout = request.query("timeout").flatMap(Double.init) ?? 0
                let deadline = Date().addingTimeInterval(min(max(timeout, 0), 30))
                while true {
                    if let file = pendingFiles().first {
                        let message = try Data(contentsOf: file)
                        if request.path == "/agent/next" {
                            try FileManager.default.removeItem(at: file)
                        }
                        send(connection, status: 200, body: message, contentType: "text/plain; charset=utf-8")
                        return
                    }
                    if Date() >= deadline {
                        send(connection, status: 204, body: nil, contentType: nil)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }

            default:
                send(connection, status: 404, body: nil, contentType: nil)
            }
        } catch {
            updateState { $0.lastError = error.localizedDescription }
            send(connection, status: 500, body: Data("Internal Server Error".utf8), contentType: "text/plain")
        }
    }

    private func setPhoneTarget(from message: Data) {
        guard let text = String(data: message, encoding: .utf8),
              let range = text.range(of: #"https?://[^\s,;)]+"#, options: .regularExpression),
              let url = URL(string: String(text[range])) else { return }
        targetStore.set(.http(url), name: url.host(percentEncoded: false), replaceBonjour: true)
    }

    private func pendingFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil, options: []))?
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: Data?, contentType: String?) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Internal Server Error"
        }
        var response = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        if let contentType { response += "Content-Type: \(contentType)\r\n" }
        response += "Content-Length: \(body?.count ?? 0)\r\n\r\n"
        var data = Data(response.utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
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
            guard let interface = item.pointee.ifa_addr, interface.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(interface, socklen_t(interface.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: host)
            if value != "127.0.0.1" {
                address = value
                if name == "en0" { break }
            }
        }
        return address
    }
}

private struct Request {
    let method: String
    let path: String
    let rawPath: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        guard let headerText = String(data: data[data.startIndex..<range.lowerBound], encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }
        method = String(requestParts[0])
        rawPath = String(requestParts[1])
        path = URLComponents(string: rawPath)?.path ?? rawPath
        lines.removeFirst()
        var parsedHeaders: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            parsedHeaders[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        headers = parsedHeaders
        body = Data(data[range.upperBound...])
    }

    func query(_ name: String) -> String? {
        guard let components = URLComponents(string: rawPath),
              let values = components.queryItems?.filter({ $0.name == name }),
              let value = values.first?.value else { return nil }
        return value
    }
}

extension Dictionary where Key == String, Value == Any {
    var sortedJSONString: String {
        NeoXPhoneClient.jsonString(self)
    }
}
