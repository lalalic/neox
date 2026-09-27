import CryptoKit
import Foundation
import Network

/// A NeoX service selected either from an explicit MCP URL (usually carried
/// by a phone handoff) or directly from the `_mcp._tcp` Bonjour endpoint.
enum NeoXPhoneTarget: Sendable {
    case http(URL)
    case bonjour(NWEndpoint)

    var kind: String {
        switch self {
        case .http: return "handoff_url"
        case .bonjour: return "bonjour"
        }
    }
}

/// Thread-safe handoff between the phone handoff receiver, Bonjour browser,
/// MCP tool handlers, and menu-bar UI.
final class NeoXPhoneTargetStore: @unchecked Sendable {
    private let lock = NSLock()
    private var target: NeoXPhoneTarget?
    private var name: String?

    func set(_ newTarget: NeoXPhoneTarget, name: String?, replaceBonjour: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if case .bonjour = target, !replaceBonjour { return }
        self.target = newTarget
        self.name = name
    }

    func snapshot() -> (target: NeoXPhoneTarget?, name: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (target, name)
    }
}

/// Browse the NeoX phone service. The browser only stores a resolved
/// NWEndpoint; all HTTP I/O happens through NeoXHTTPTransport so macOS can
/// resolve the mDNS service without reconstructing a `.local` URL.
final class NeoXServiceDiscovery: @unchecked Sendable {
    struct Service: Identifiable, Sendable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    private let excludedNames: Set<String>
    private let update: @Sendable ([Service]) -> Void
    private let lock = NSLock()
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "neoy.neox-discovery", qos: .userInitiated)

    init(excludedNames: Set<String> = ["neox-tour-mac", "NeoY", "neoy"],
         update: @escaping @Sendable ([Service]) -> Void) {
        self.excludedNames = excludedNames
        self.update = update
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_mcp._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services: [Service] = results.compactMap { result in
                guard case .service(let name, let type, _, _) = result.endpoint,
                      type == "_mcp._tcp", !(self?.excludedNames.contains(name) ?? false)
                else { return nil }
                return Service(id: "\(name).\(type)", name: name, endpoint: result.endpoint)
            }
            self?.update(services)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.stop() }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        lock.lock()
        let oldBrowser = browser
        browser = nil
        lock.unlock()
        oldBrowser?.cancel()
        update([])
    }
}

/// Minimal first-party HTTP transport used by the native NeoX client. The
/// Bonjour branch avoids buffering downloads: bytes are written as they arrive.
enum NeoXHTTPTransport {
    static func request(
        _ target: NeoXPhoneTarget,
        path: String,
        method: String = "GET",
        contentType: String? = nil,
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> (data: Data, status: Int, headers: [String: String]) {
        switch target {
        case .http(let base):
            guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
                throw NeoYClientError.invalidURL("\(base)\(path)")
            }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = method
            request.httpBody = body
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            return (data, http?.statusCode ?? 0, responseHeaders(http))
        case .bonjour(let endpoint):
            let request = wireRequest(path: path, method: method, contentType: contentType, body: body)
            return try await exchange(endpoint: endpoint, request: request, timeout: timeout)
        }
    }

    static func download(
        _ target: NeoXPhoneTarget,
        path: String,
        to destination: URL,
        timeout: TimeInterval = 300
    ) async throws -> Int64 {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)

        switch target {
        case .http(let base):
            guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
                throw NeoYClientError.invalidURL("\(base)\(path)")
            }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let (fileURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NeoYClientError.http(status)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: fileURL, to: destination)
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return size

        case .bonjour(let endpoint):
            let request = wireRequest(path: path, method: "GET", contentType: nil, body: nil)
            return try await stream(
                endpoint: endpoint,
                request: request,
                timeout: timeout,
                destination: destination
            ) { handle, chunk in try handle.write(contentsOf: chunk) }
        }
    }

    private static func wireRequest(
        path: String, method: String, contentType: String?, body: Data?
    ) -> Data {
        var request = "\(method) \(path.isEmpty ? "/" : path) HTTP/1.1\r\nHost: neox.local\r\nConnection: close\r\nAccept: */*\r\n"
        if let contentType { request += "Content-Type: \(contentType)\r\n" }
        if let body { request += "Content-Length: \(body.count)\r\n" }
        request += "\r\n"
        var data = Data(request.utf8)
        if let body { data.append(body) }
        return data
    }

    private static func exchange(
        endpoint: NWEndpoint, request: Data, timeout: TimeInterval
    ) async throws -> (Data, Int, [String: String]) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }
        try await connect(connection, timeout: timeout)
        try await send(request, connection: connection)

        var received = Data()
        while true {
            let chunk = try await receive(connection: connection)
            if chunk.isEmpty { break }
            received.append(chunk)
            if let complete = parseCompleteResponse(received) { return complete }
        }
        guard let complete = parseCompleteResponse(received) else {
            throw NeoYClientError.invalidResponse("connection closed before a complete HTTP response")
        }
        return complete
    }

    private static func stream(
        endpoint: NWEndpoint,
        request: Data,
        timeout: TimeInterval,
        destination: URL,
        write: (FileHandle, Data) throws -> Void
    ) async throws -> Int64 {
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }
        try await connect(connection, timeout: timeout)
        try await send(request, connection: connection)

        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffered = Data()
        var size: Int64 = 0
        var responseStarted = false
        var expected: Int?
        while true {
            let chunk = try await receive(connection: connection)
            if chunk.isEmpty { break }
            if !responseStarted {
                buffered.append(chunk)
                guard let (status, headers, body) = splitHeaders(buffered) else { continue }
                guard (200..<300).contains(status) else {
                    throw NeoYClientError.http(status)
                }
                if let contentLength = headers["content-length"] { expected = Int(contentLength) }
                if !body.isEmpty { try write(handle, body); size += Int64(body.count) }
                responseStarted = true
                if let expected, size >= Int64(expected) { break }
            } else {
                try write(handle, chunk)
                size += Int64(chunk.count)
                if let expected, size >= Int64(expected) { break }
            }
        }
        guard responseStarted else { throw NeoYClientError.invalidResponse("empty HTTP response") }
        return size
    }

    private static func parseCompleteResponse(_ data: Data) -> (Data, Int, [String: String])? {
        guard let (status, headers, body) = splitHeaders(data) else { return nil }
        if let value = headers["content-length"], let length = Int(value) {
            guard body.count >= length else { return nil }
            return (body.prefix(length), status, headers)
        }
        return (body, status, headers)
    }

    private static func splitHeaders(_ data: Data) -> (Int, [String: String], Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let headerData = data[data.startIndex..<range.lowerBound]
        let body = data[range.upperBound...]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/"),
              let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else { return nil }
        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers, Data(body))
    }

    private static func responseHeaders(_ response: HTTPURLResponse?) -> [String: String] {
        let values = response?.allHeaderFields as? [String: String] ?? [:]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.key.lowercased(), $0.value) })
    }

    private static func connect(_ connection: NWConnection, timeout: TimeInterval) async throws {
        let box = ContinuationBox<CheckedContinuation<Void, Error>>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.consume()?.resume()
            case .failed(let error), .waiting(let error):
                box.consume()?.resume(throwing: error)
            case .cancelled:
                box.consume()?.resume(throwing: NeoYClientError.cancelled)
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        try await withCheckedThrowingContinuation { box.store($0) }
    }

    private static func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func receive(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(returning: Data()) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }
}

final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func store(_ continuation: T) {
        lock.lock()
        value = continuation
        lock.unlock()
    }

    func consume() -> T? {
        lock.lock()
        defer { lock.unlock() }
        let value = value
        self.value = nil
        return value
    }
}

enum NeoYClientError: LocalizedError {
    case invalidURL(String)
    case invalidResponse(String)
    case http(Int)
    case cancelled
    case phoneUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "Invalid NeoX URL: \(value)"
        case .invalidResponse(let value): return value
        case .http(let status): return "NeoX returned HTTP \(status)"
        case .cancelled: return "NeoX request was cancelled"
        case .phoneUnavailable(let reason): return "NeoX phone is unavailable: \(reason)"
        }
    }
}

/// Native MCP client for the authoritative NeoX phone service.
final class NeoXPhoneClient: NeoYPhoneClient, @unchecked Sendable {
    private let targetStore: NeoXPhoneTargetStore
    private let files: NeoYFileService
    private let discoveryLock = NSLock()
    private var discovery: NeoXServiceDiscovery?

    init(targetStore: NeoXPhoneTargetStore, files: NeoYFileService) {
        self.targetStore = targetStore
        self.files = files
    }

    func startDiscovery() {
        discoveryLock.lock()
        if discovery != nil {
            discoveryLock.unlock()
            return
        }
        let discovery = NeoXServiceDiscovery { [weak self] services in
            guard let self, let service = services.first else { return }
            self.targetStore.set(.bonjour(service.endpoint), name: service.name, replaceBonjour: true)
        }
        discovery.start()
        self.discovery = discovery
        discoveryLock.unlock()
    }

    func stopDiscovery() {
        discoveryLock.lock()
        let oldDiscovery = discovery
        discovery = nil
        discoveryLock.unlock()
        oldDiscovery?.stop()
    }

    func setHandoffURL(_ url: URL) {
        targetStore.set(.http(url), name: url.host(percentEncoded: false), replaceBonjour: true)
    }

    func targetSummary() -> [String: Any] {
        let (target, name) = targetStore.snapshot()
        var value: [String: Any] = ["selected": target != nil, "name": name ?? NSNull()]
        if let target { value["kind"] = target.kind }
        if case .http(let url) = target { value["url"] = url.absoluteString }
        return value
    }

    private func target() throws -> NeoXPhoneTarget {
        guard let target = targetStore.snapshot().target else {
            throw NeoYClientError.phoneUnavailable("no NeoX handoff URL or _mcp._tcp service found")
        }
        return target
    }

    func status() async throws -> String {
        let target = try target()
        let response = try await NeoXHTTPTransport.request(target, path: "/")
        guard (200..<300).contains(response.status) else { throw NeoYClientError.http(response.status) }
        guard var banner = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw NeoYClientError.invalidResponse("NeoX banner is not JSON")
        }
        banner["selected"] = true
        banner["selection_kind"] = target.kind
        return Self.jsonString(banner)
    }

    func callTool(_ name: String, arguments: JSONValue, timeout: TimeInterval = 60) async throws -> String {
        let target = try target()
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments.anyJSON],
        ], options: [.sortedKeys])
        let response = try await NeoXHTTPTransport.request(
            target, path: "/mcp", method: "POST", contentType: "application/json",
            body: body, timeout: timeout)
        guard (200..<300).contains(response.status) else { throw NeoYClientError.http(response.status) }
        let rpc = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        if let error = rpc?["error"] as? [String: Any] {
            throw NeoYClientError.invalidResponse("NeoX MCP error: \(error)")
        }
        guard let result = rpc?["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else {
            throw NeoYClientError.invalidResponse("NeoX MCP result has no content")
        }
        for item in content {
            if let text = item["text"] as? String {
                if text.hasPrefix("Error: ") { throw NeoYClientError.invalidResponse(String(text.dropFirst(7))) }
                return text
            }
        }
        throw NeoYClientError.invalidResponse("NeoX MCP returned non-text content")
    }

    func search(arguments: JSONValue) async throws -> String {
        try await callTool("media.search", arguments: arguments)
    }

    func metadata(arguments: JSONValue) async throws -> String {
        try await callTool("media.meta", arguments: arguments)
    }

    func thumbnail(arguments: JSONValue) async throws -> String {
        try await callTool("media.thumbnail", arguments: arguments)
    }

    func exportAndDownload(arguments: JSONValue) async throws -> String {
        guard case .object(let input) = arguments else {
            throw NeoYClientError.invalidResponse("arguments must be an object")
        }
        var ids: [String] = []
        if case .array(let values)? = input["ids"] {
            for case .string(let id) in values { ids.append(id) }
        }
        guard !ids.isEmpty else { throw NeoYClientError.invalidResponse("'ids' must contain at least one asset id") }
        let preset: String
        if case .string(let value)? = input["preset"] { preset = value } else { preset = "original" }

        let exportText = try await callTool("media.export", arguments: arguments, timeout: 600)
        guard let exportData = exportText.data(using: .utf8),
              var result = try? JSONSerialization.jsonObject(with: exportData) as? [String: Any],
              let exports = result["exports"] as? [[String: Any]] else {
            throw NeoYClientError.invalidResponse("media.export returned invalid JSON")
        }

        let target = try target()
        var downloaded: [[String: Any]] = []
        var errors: [String] = []
        for export in exports {
            do {
                guard let id = export["id"] as? String,
                      let sourcePath = export["url"] as? String else {
                    throw NeoYClientError.invalidResponse("export entry lacks id/url")
                }
                let destination = try localDestination(id: id, preset: preset, export: export)
                let size = try await NeoXHTTPTransport.download(
                    target, path: sourcePath, to: destination)
                var item = export
                item["local_path"] = destination.path
                item["local_file_url"] = destination.absoluteURL.absoluteString
                item["local_reference"] = files.reference(for: destination, in: files.phoneExports)
                item["size_bytes"] = size
                item["downloaded"] = true
                downloaded.append(item)
            } catch {
                errors.append("\(export["id"] ?? "unknown"): \(error.localizedDescription)")
            }
        }
        result["exports"] = downloaded
        result["downloaded_count"] = downloaded.count
        if !errors.isEmpty { result["errors"] = errors }
        return Self.jsonString(result)
    }

    private func localDestination(id: String, preset: String, export: [String: Any]) throws -> URL {
        let digest = SHA256.hash(data: Data(id.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        let originalName = export["original_name"] as? String
        let sourceName = export["file"] as? String
        let extensionSource = originalName ?? sourceName ?? "media.bin"
        let pathExtension = (extensionSource as NSString).pathExtension.lowercased()
        let ext = pathExtension.isEmpty ? "bin" : pathExtension
        let prefix = preset == "original" ? "original" : preset
        return files.phoneExports.appendingPathComponent("neox-\(digest)-\(prefix).\(ext)")
    }

    static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension JSONValue {
    var anyJSON: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.anyJSON)
        case .object(let values): return values.mapValues(\.anyJSON)
        }
    }
}
