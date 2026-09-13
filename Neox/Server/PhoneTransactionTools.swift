import Foundation

enum PhoneTransactionTools {
    static func tools() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "phone.transaction.start",
                description: """
                Begin an explicit phone transaction before the first phone-dependent operation. \
                Keep NeoX foregrounded until phone.transaction.end succeeds. Returns an opaque \
                transaction_id to pass to every end call.
                """,
                parameters: MediaTools.schema([
                    "label": MediaTools.stringProp("Short workflow label shown on the phone (default: Desktop workflow)"),
                    "reason": MediaTools.stringProp("Short reason the phone must stay foregrounded"),
                    "timeout_minutes": .object([
                        "type": .string("integer"),
                        "description": .string("Recovery timeout in minutes"),
                        "default": .int(30),
                        "minimum": .int(1),
                        "maximum": .int(240),
                    ]),
                ]),
                handler: { args in
                    await ServerController.shared.startTransaction(args)
                }
            ),
            ToolDefinition(
                name: "phone.transaction.end",
                description: """
                End the phone transaction immediately after the last phone-dependent operation. \
                The matching transaction_id and an outcome of completed, failed, or cancelled are required. \
                After success, remaining desktop work must not require NeoX foreground.
                """,
                parameters: MediaTools.schema([
                    "transaction_id": MediaTools.stringProp("Opaque id returned by phone.transaction.start"),
                    "outcome": MediaTools.stringProp("Completed, failed, or cancelled", enumVals: ["completed", "failed", "cancelled"]),
                ], required: ["transaction_id", "outcome"]),
                handler: { args in
                    await ServerController.shared.endTransaction(args)
                }
            ),
        ]
    }

    static func displayText(_ value: String, fallback: String) -> String {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return compact.isEmpty ? fallback : String(compact.prefix(100))
    }

    static func outcome(_ value: String?) -> PhoneTransactionState? {
        switch value {
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default: nil
        }
    }

    static func startedJSON(_ transaction: PhoneTransactionSnapshot) -> String {
        MediaTools.jsonString([
            "transaction_id": transaction.id.uuidString,
            "label": transaction.label,
            "reason": transaction.reason ?? NSNull(),
            "state": stateName(transaction.state),
            "started_at": MediaTools.iso8601.string(from: transaction.startedAt),
            "expires_at": MediaTools.iso8601.string(from: transaction.expiresAt),
            "timeout_minutes": transaction.timeoutMinutes,
        ])
    }

    static func endedJSON(
        _ transaction: PhoneTransactionSnapshot,
        alreadyReleased: Bool
    ) -> String {
        MediaTools.jsonString([
            "transaction_id": transaction.id.uuidString,
            "state": alreadyReleased ? "already_released" : "released",
            "outcome": stateName(transaction.state),
            "ended_at": transaction.endedAt.map { MediaTools.iso8601.string(from: $0) } ?? NSNull(),
            "message": releaseMessage(transaction.state),
        ])
    }

    private static func releaseMessage(_ state: PhoneTransactionState) -> String {
        switch state {
        case .completed:
            "Phone work complete. NeoX is released; you can use the phone normally. Desktop processing may continue."
        case .failed:
            "Phone work failed. NeoX is released; you can use the phone normally. Desktop processing status is unchanged."
        case .cancelled:
            "Phone work cancelled. NeoX is released; you can use the phone normally. Desktop processing status is unchanged."
        case .timeout:
            "Phone work timed out. NeoX is released; you can use the phone normally. Desktop processing status is unchanged."
        case .active:
            "NeoX phone work is active; keep NeoX in the foreground."
        }
    }

    private static func stateName(_ state: PhoneTransactionState) -> String {
        switch state {
        case .active: "active"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .timeout: "timeout"
        }
    }
}

extension PhoneTransactionEndResult {
    var isAlreadyReleased: Bool {
        if case .alreadyReleased = self { return true }
        return false
    }
}
