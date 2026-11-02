import Foundation

enum MarkcutReviewChoice: String, Codable {
    case approved
    case changesRequested = "changes_requested"
}

struct MarkcutReviewComment: Codable, Equatable {
    let scope: String
    let text: String
}

struct MarkcutReviewDecision: Codable, Equatable, Identifiable {
    let sessionID: String
    let contentHash: String
    let choice: MarkcutReviewChoice
    let comments: [MarkcutReviewComment]
    let idempotencyKey: String
    var id: String { idempotencyKey }

    init(sessionID: String, contentHash: String, choice: MarkcutReviewChoice,
         comments: [MarkcutReviewComment], idempotencyKey: String = UUID().uuidString) throws {
        guard UUID(uuidString: sessionID) != nil,
              contentHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              idempotencyKey.count >= 8, idempotencyKey.count <= 128 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        guard (choice == .changesRequested && !comments.isEmpty && comments.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })) ||
              (choice == .approved && comments.isEmpty) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        self.sessionID = sessionID
        self.contentHash = contentHash
        self.choice = choice
        self.comments = comments
        self.idempotencyKey = idempotencyKey
    }

    var mcpArguments: [String: Any] {
        ["sessionId":sessionID,"contentHash":contentHash,"decision":choice.rawValue,
         "comments":comments.map { ["scope":$0.scope,"text":$0.text] },"idempotencyKey":idempotencyKey]
    }

    static func loadQueue(from defaults: UserDefaults) -> [String: MarkcutReviewDecision] {
        guard let data = defaults.data(forKey: "markcut.review.pending"),
              let queue = try? JSONDecoder().decode([String: MarkcutReviewDecision].self, from: data) else { return [:] }
        return queue
    }

    static func saveQueue(_ queue: [String: MarkcutReviewDecision], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: "markcut.review.pending")
    }
}
