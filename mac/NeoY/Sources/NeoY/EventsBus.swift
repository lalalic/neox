import Foundation

enum NeoYEventsError: LocalizedError {
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Events Bus returned an invalid response"
        case .http(let status, let body): "Events Bus HTTP \(status): \(body)"
        }
    }
}

struct NeoYEventsBusClient: Sendable {
    let apiURL: URL

    init(apiURL: URL? = nil) {
        if let apiURL {
            self.apiURL = apiURL
            return
        }
        let runtime = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EventsBus/runtime.json")
        if let data = try? Data(contentsOf: runtime),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["apiUrl"] as? String,
           let url = URL(string: value) {
            self.apiURL = url
        } else {
            self.apiURL = URL(string: "http://127.0.0.1:4223")!
        }
    }

    func health() async throws -> String {
        try await get("/health")
    }

    func history(jobID: String, after: Int = 0, limit: Int = 100) async throws -> String {
        try await get("/events", query: [
            URLQueryItem(name: "job", value: jobID),
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    func status(jobID: String) async throws -> String {
        try await get("/status", query: [URLQueryItem(name: "job", value: jobID)])
    }

    func wait(jobID: String, after: Int = 0, timeoutMS: Int = 25_000, limit: Int = 100) async throws -> String {
        try await get("/wait", query: [
            URLQueryItem(name: "job", value: jobID),
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "timeout", value: String(timeoutMS)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    func publish(event: [String: Any]) async throws -> String {
        var request = URLRequest(url: apiURL.appendingPathComponent("events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["event": event])
        return try await perform(request)
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> String {
        var components = URLComponents(url: apiURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return try await perform(URLRequest(url: components.url!))
    }

    private func perform(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NeoYEventsError.invalidResponse }
        let body = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(http.statusCode) else {
            throw NeoYEventsError.http(http.statusCode, body)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw NeoYEventsError.invalidResponse
        }
        return body
    }
}

enum NeoYEventsTools {
    static func tools(client: NeoYEventsBusClient = NeoYEventsBusClient()) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "events.health",
                description: "Check NeoY's shared Events Bus core capability.",
                parameters: .object(["type": .string("object"), "properties": .object([:])])
            ) { _ in try await client.health() },
            ToolDefinition(
                name: "events.status",
                description: "Return latest and terminal Events Bus state for one correlation/job id.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["job_id": .object(["type": .string("string")])]),
                    "required": .array([.string("job_id")]),
                ])
            ) { arguments in
                guard case .object(let object) = arguments, case .string(let jobID)? = object["job_id"] else {
                    throw NeoYEventsError.invalidResponse
                }
                return try await client.status(jobID: jobID)
            },
            ToolDefinition(
                name: "events.history",
                description: "Read shared Events Bus history after a cursor.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object(["type": .string("string")]),
                        "after_cursor": .object(["type": .string("integer")]),
                        "limit": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("job_id")]),
                ])
            ) { arguments in
                guard case .object(let object) = arguments, case .string(let jobID)? = object["job_id"] else {
                    throw NeoYEventsError.invalidResponse
                }
                let after: Int
                if case .int(let value)? = object["after_cursor"] { after = value } else { after = 0 }
                let limit: Int
                if case .int(let value)? = object["limit"] { limit = value } else { limit = 100 }
                return try await client.history(jobID: jobID, after: after, limit: limit)
            },
            ToolDefinition(
                name: "events.wait",
                description: "Wait for shared Events Bus events after a cursor.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object(["type": .string("string")]),
                        "after_cursor": .object(["type": .string("integer")]),
                        "timeout_ms": .object(["type": .string("integer")]),
                        "limit": .object(["type": .string("integer")]),
                    ]),
                    "required": .array([.string("job_id")]),
                ])
            ) { arguments in
                guard case .object(let object) = arguments, case .string(let jobID)? = object["job_id"] else {
                    throw NeoYEventsError.invalidResponse
                }
                let after = object["after_cursor"].flatMap { if case .int(let v) = $0 { return v }; return nil } ?? 0
                let timeout = object["timeout_ms"].flatMap { if case .int(let v) = $0 { return v }; return nil } ?? 25_000
                let limit = object["limit"].flatMap { if case .int(let v) = $0 { return v }; return nil } ?? 100
                return try await client.wait(jobID: jobID, after: after, timeoutMS: timeout, limit: limit)
            },
            ToolDefinition(
                name: "events.publish",
                description: "Publish a feature/core event through NeoY's shared Events Bus.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "job_id": .object(["type": .string("string")]),
                        "task_id": .object(["type": .string("string")]),
                        "type": .object(["type": .string("string")]),
                        "status": .object(["type": .string("string")]),
                        "visibility": .object(["type": .string("string")]),
                        "message": .object(["type": .string("string")]),
                        "data": .object(["type": .string("object")]),
                    ]),
                    "required": .array([.string("job_id"), .string("task_id"), .string("type"), .string("status"), .string("visibility"), .string("message")]),
                ])
            ) { arguments in
                guard case .object(let object) = arguments else { throw NeoYEventsError.invalidResponse }
                func string(_ key: String) throws -> String {
                    guard case .string(let value)? = object[key] else { throw NeoYEventsError.invalidResponse }
                    return value
                }
                var event: [String: Any] = [
                    "job_id": try string("job_id"),
                    "task_id": try string("task_id"),
                    "type": try string("type"),
                    "status": try string("status"),
                    "visibility": try string("visibility"),
                    "message": try string("message"),
                    "source": ["id": "neoy"],
                ]
                if case .object(let data)? = object["data"] {
                    event["data"] = data.mapValues { $0.foundationValue }
                }
                return try await client.publish(event: event)
            },
        ]
    }
}

private extension JSONValue {
    var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        case .null: NSNull()
        case .array(let values): values.map(\.foundationValue)
        case .object(let values): values.mapValues(\.foundationValue)
        }
    }
}
