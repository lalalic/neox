import Foundation

enum MarkcutReviewRequestTool {
    static func tools() -> [ToolDefinition] {
        [ToolDefinition(name: "review.request",
            description: "Add one explicit video review request to this phone's local Review Inbox.",
            parameters: MediaTools.schema([
                "id": stringProp("Stable UUID for idempotent request delivery", pattern: "^[0-9a-fA-F-]{36}$"),
                "contentHash": stringProp("Lowercase SHA-256 of the immutable preview revision", pattern: "^[a-f0-9]{64}$"),
                "revisionId": stringProp("Nonempty immutable revision identifier", minLength: 1),
                "title": stringProp("Review title shown on the phone", minLength: 1),
                "groupId": MediaTools.stringProp("Optional stable grouping identifier"),
                "groupTitle": MediaTools.stringProp("Optional title for a grouped set of revisions"),
                "jobId": MediaTools.stringProp("Optional originating job identifier"),
                "ownerCallbackTool": MediaTools.stringProp("Owner callback: chatgpt for a thread, or an approved review.feedback MCP tool"),
                "ownerThreadId": MediaTools.stringProp("Required for chatgpt callback: originating ChatGPT thread ID"),
                "playerUrl": MediaTools.stringProp("Optional immutable HTTPS player bundle URL")
            ], required: ["id", "contentHash", "revisionId", "title"]),
            handler: { args in
                do {
                    let data = try JSONEncoder().encode(args)
                    let request = try JSONDecoder().decode(MarkcutReviewRequest.self, from: data)
                    let inserted = try await MainActor.run {
                        let inbox = MarkcutReviewInboxStore.shared
                        if let prior = inbox.request(id: request.id), prior != request {
                            throw CocoaError(.validationMultipleErrors)
                        }
                        return inbox.accept(request)
                    }
                    return "{\"accepted\":true,\"duplicate\":\(!inserted),\"id\":\(try Self.jsonString(request.id))}"
                } catch {
                    return "Error: invalid review request"
                }
            })]
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value])
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }

    private static func stringProp(_ description: String, pattern: String? = nil,
                                   minLength: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let pattern { value["pattern"] = .string(pattern) }
        if let minLength { value["minLength"] = .int(minLength) }
        return .object(value)
    }
}
