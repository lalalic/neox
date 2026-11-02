import Foundation
import UserNotifications

struct MarkcutReviewRequest: Codable, Identifiable, Equatable {
    let id: String
    let contentHash: String
    let revisionID: String
    let title: String
    let groupID: String?
    let groupTitle: String?
    let jobID: String?
    let ownerCallbackTool: String?
    let playerURL: String?

    enum CodingKeys: String, CodingKey {
        case id, contentHash, title, groupTitle
        case revisionID = "revisionId"
        case groupID = "groupId"
        case jobID = "jobId"
        case ownerCallbackTool, playerURL = "playerUrl"
    }

    init(id: String, contentHash: String, revisionID: String, title: String,
         groupID: String? = nil, groupTitle: String? = nil, jobID: String? = nil,
         ownerCallbackTool: String? = nil, playerURL: String? = nil) throws {
        guard UUID(uuidString: id) != nil,
              contentHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !revisionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ownerCallbackTool.map({ $0 == "review.feedback" || $0.hasSuffix(".review.feedback") }) ?? true,
              playerURL.map({ URL(string: $0)?.scheme == "https" }) ?? true else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        self.id = id
        self.contentHash = contentHash
        self.revisionID = revisionID
        self.title = title
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.jobID = jobID
        self.ownerCallbackTool = ownerCallbackTool
        self.playerURL = playerURL
    }

    // JSONDecoder does not call the memberwise validating initializer.
    // Validate untrusted MCP requests even when decoded from wire JSON.
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: fields.decode(String.self, forKey: .id),
            contentHash: fields.decode(String.self, forKey: .contentHash),
            revisionID: fields.decode(String.self, forKey: .revisionID),
            title: fields.decode(String.self, forKey: .title),
            groupID: fields.decodeIfPresent(String.self, forKey: .groupID),
            groupTitle: fields.decodeIfPresent(String.self, forKey: .groupTitle),
            jobID: fields.decodeIfPresent(String.self, forKey: .jobID),
            ownerCallbackTool: fields.decodeIfPresent(String.self, forKey: .ownerCallbackTool),
            playerURL: fields.decodeIfPresent(String.self, forKey: .playerURL)
        )
    }

    var groupingValue: [String: Any] {
        var value: [String: Any] = ["id": id, "revisionId": revisionID, "contentHash": contentHash,
                                    "title": title, "status": "ready"]
        if let groupID { value["videoGroupKey"] = groupID }
        if let groupTitle { value["videoGroupTitle"] = groupTitle }
        if let jobID { value["relayCorrelations"] = [["jobId": jobID]] }
        if let playerURL { value["playerUrl"] = playerURL }
        return value
    }
}

struct MarkcutReviewFeedback: Codable, Equatable, Identifiable {
    let requestId: String
    let decision: MarkcutReviewChoice
    let feedback: String
    let idempotencyKey: String
    var id: String { requestId }

    static func requireAcknowledgement(_ result: [String: Any]) throws {
        guard result["acknowledged"] as? Bool == true else {
            throw NSError(domain: "MarkcutReviewFeedback", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Owner tool did not acknowledge feedback"])
        }
    }
}

@MainActor
final class MarkcutReviewInboxStore: ObservableObject {
    static let shared = MarkcutReviewInboxStore()
    private let requestsKey = "markcut.review.inbox.v2"
    private let feedbackKey = "markcut.review.feedback.v2"
    private let defaults: UserDefaults
    @Published private(set) var requests: [MarkcutReviewRequest]
    @Published private(set) var feedbackQueue: [MarkcutReviewFeedback]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requests = (try? JSONDecoder().decode([MarkcutReviewRequest].self,
            from: defaults.data(forKey: requestsKey) ?? Data())) ?? []
        feedbackQueue = (try? JSONDecoder().decode([MarkcutReviewFeedback].self,
            from: defaults.data(forKey: feedbackKey) ?? Data())) ?? []
    }

    @discardableResult
    func accept(_ request: MarkcutReviewRequest, notify: Bool = true) -> Bool {
        guard !requests.contains(where: { $0.id == request.id }) else { return false }
        requests.insert(request, at: 0)
        saveRequests()
        if notify { notifyForNewRequest(request) }
        return true
    }

    func remove(_ id: String) {
        guard !feedbackQueue.contains(where: { $0.requestId == id }) else { return }
        requests.removeAll { $0.id == id }
        saveRequests()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["markcut-review-\(id)"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["markcut-review-\(id)"])
    }

    func queue(_ feedback: MarkcutReviewFeedback) {
        guard !feedbackQueue.contains(where: { $0.requestId == feedback.requestId }) else { return }
        feedbackQueue.append(feedback)
        saveFeedback()
    }

    func acknowledge(_ feedback: MarkcutReviewFeedback) {
        feedbackQueue.removeAll { $0.id == feedback.id }
        requests.removeAll { $0.id == feedback.requestId }
        saveFeedback()
        saveRequests()
    }

    func request(id: String) -> MarkcutReviewRequest? { requests.first { $0.id == id } }

    private func saveRequests() {
        if let data = try? JSONEncoder().encode(requests) { defaults.set(data, forKey: requestsKey) }
    }

    private func saveFeedback() {
        if let data = try? JSONEncoder().encode(feedbackQueue) { defaults.set(data, forKey: feedbackKey) }
    }

    private func notifyForNewRequest(_ request: MarkcutReviewRequest) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Video ready for review"
            content.body = request.title
            content.sound = .default
            content.userInfo = ["reviewRequestId": request.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "markcut-review-\(request.id)",
                                                                           content: content, trigger: nil))
        }
    }
}
