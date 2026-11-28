import Foundation

/// Internal authenticated REST/SSE transport for the unified Neo gateway.
/// Model and Relay business state remain owned by their loopback services.
enum GatewayRESTError: Error {
    case invalidEndpoint, invalidResponse, http(Int), malformedSSE(String)
}

final class UnifiedGatewayREST: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let token: String
    private let credentialProvider: (@MainActor () async throws -> String)?

    init(origin: URL, token: String, credentialProvider: (@MainActor () async throws -> String)? = nil) throws {
        guard ["http", "https"].contains(origin.scheme ?? ""),
              origin.host != nil, origin.user == nil, origin.password == nil,
              !token.isEmpty else { throw GatewayRESTError.invalidEndpoint }
        self.origin = origin
        self.token = token
        self.credentialProvider = credentialProvider
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // A Mobile bearer must never follow a redirect to another origin.
        completionHandler(nil)
    }

    @MainActor private func makeRequest(_ method: String, path: String, query: [URLQueryItem], body: [String: Any]?) async throws -> URLRequest {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains(".."), !path.contains("%"),
              !path.contains("?"), !path.contains("#"),
              path.hasPrefix("/orchestrator-chat/") || path.hasPrefix("/relay/api/") else {
            throw GatewayRESTError.invalidEndpoint
        }
        var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        url.path = path
        url.queryItems = query.isEmpty ? nil : query
        guard let target = url.url else { throw GatewayRESTError.invalidEndpoint }
        var request = URLRequest(url: target)
        request.httpMethod = method
        let current = try await credentialProvider?() ?? token
        request.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            guard JSONSerialization.isValidJSONObject(body) else { throw GatewayRESTError.invalidResponse }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if method == "POST" && path == "/orchestrator-chat/messages" {
                guard let requestID = body["requestId"] as? String, !requestID.isEmpty else {
                    throw GatewayRESTError.invalidResponse
                }
                request.setValue(requestID, forHTTPHeaderField: "Idempotency-Key")
            }
        }
        return request
    }

    @MainActor func json(_ method: String, path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
              expectedStatus: Int = 200) async throws -> [String: Any] {
        guard let object = try await jsonValue(method, path: path, query: query, body: body,
                                               expectedStatus: expectedStatus) as? [String: Any] else {
            throw GatewayRESTError.invalidResponse
        }
        return object
    }

    @MainActor func jsonArray(_ method: String, path: String, query: [URLQueryItem] = [],
                              expectedStatus: Int = 200) async throws -> [[String: Any]] {
        guard let rows = try await jsonValue(method, path: path, query: query, body: nil,
                                              expectedStatus: expectedStatus) as? [[String: Any]] else {
            throw GatewayRESTError.invalidResponse
        }
        return rows
    }

    @MainActor private func jsonValue(_ method: String, path: String, query: [URLQueryItem],
                                      body: [String: Any]?, expectedStatus: Int) async throws -> Any {
        let request = try await makeRequest(method, path: path, query: query, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == expectedStatus else {
            throw GatewayRESTError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONSerialization.jsonObject(with: bytes)
    }

    /// Bearer-authenticated Relay notifications contain no Job payload, prompts
    /// or event text. The authoritative Jobs/Activity data is re-fetched by REST.
    @MainActor func relayChanges(onConnected: @escaping @MainActor () async -> Void = {},
                                 onChange: @escaping @MainActor () async -> Void) async throws {
        var request = try await makeRequest("GET", path: "/relay/api/mobile/events",
                                      query: [], body: nil)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
            throw GatewayRESTError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        await onConnected()
        var eventName = ""
        var dataLines: [String] = []
        var wire = GatewaySSELineBuffer(maxLineBytes: 1024)
        // Foundation AsyncBytes.lines skips blank SSE delimiter lines on real
        // URLSession streams. Parse bytes directly so frame boundaries survive.
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let line = try wire.append(byte) else { continue }
            let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanLine.isEmpty {
                if eventName == "change" {
                    guard dataLines.count == 1 else {
                        throw GatewayRESTError.malformedSSE("dataLineCount=\(dataLines.count)")
                    }
                    guard let data = dataLines[0].data(using: .utf8), data.count <= 256 else {
                        throw GatewayRESTError.malformedSSE("payloadSizeOverLimit")
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw GatewayRESTError.malformedSSE("notJSONDictionary")
                    }
                    guard json.count == 1, json["refresh"] as? Bool == true else {
                        throw GatewayRESTError.malformedSSE("invalidRefreshMarker fields=\(json.count)")
                    }
                    await onChange()
                }
                dataLines.removeAll(keepingCapacity: true)
                eventName = ""
            } else if cleanLine.hasPrefix("event:") {
                eventName = String(cleanLine.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if cleanLine.hasPrefix("data:") {
                guard dataLines.count < 2 else { throw GatewayRESTError.malformedSSE("excessDataLines") }
                dataLines.append(String(cleanLine.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    /// A caller must persist the received message BEFORE advancing its cursor.
    func events(after cursor: Int, onEvent: @escaping @MainActor (Data) async throws -> Void) async throws {
        guard cursor >= 0 else { throw GatewayRESTError.invalidResponse }
        var request = try await makeRequest("GET", path: "/orchestrator-chat/events",
                                      query: [URLQueryItem(name: "cursor", value: String(cursor))], body: nil)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 3600
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
            throw GatewayRESTError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        var dataLines: [String] = []
        var wire = GatewaySSELineBuffer(maxLineBytes: 256 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard let line = try wire.append(byte) else { continue }
            if line.isEmpty {
                if !dataLines.isEmpty {
                    guard let data = dataLines.joined(separator: "\n").data(using: .utf8),
                          data.count <= 256 * 1024 else {
                        throw GatewayRESTError.invalidResponse
                    }
                    try await onEvent(data)
                    dataLines.removeAll(keepingCapacity: true)
                }
            } else if line.hasPrefix("data:") {
                guard dataLines.count < 16 else { throw GatewayRESTError.invalidResponse }
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
    }
}

/// Byte-exact SSE line decoder. URLSession.AsyncBytes.lines can suppress empty
/// lines, but SSE uses those lines to terminate complete events. Keep each
/// separator (including CRLF) without exposing or buffering raw event bodies
/// beyond the caller's explicit size limit.
struct GatewaySSELineBuffer {
    let maxLineBytes: Int
    private var pending = Data()

    init(maxLineBytes: Int) { self.maxLineBytes = maxLineBytes }

    mutating func append(_ byte: UInt8) throws -> String? {
        if byte == 10 { // LF; CRLF is normalized below
            if pending.last == 13 { pending.removeLast() }
            guard let line = String(data: pending, encoding: .utf8) else {
                throw GatewayRESTError.invalidResponse
            }
            pending.removeAll(keepingCapacity: true)
            return line // Empty string is a meaningful SSE frame delimiter.
        }
        guard pending.count < maxLineBytes else { throw GatewayRESTError.invalidResponse }
        pending.append(byte)
        return nil
    }
}
