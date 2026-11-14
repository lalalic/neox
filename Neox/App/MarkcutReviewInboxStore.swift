import Foundation
import UserNotifications

struct MarkcutReviewEventTemplate: Codable, Equatable {
    let type: String
    let source: String
    let data: [String: JSONValue]
    let responseKey: String?

    init(type: String, source: String, data: [String: JSONValue], responseKey: String? = nil) {
        self.type = type
        self.source = source
        self.data = data
        self.responseKey = responseKey
    }

    func validate() throws {
        // Generic event envelope: no Relay event name, Task ID, or execution validation here.
        let key = responseKey ?? "review"
        guard type.range(of: #"^[A-Za-z0-9_.:-]{1,128}$"#, options: .regularExpression) != nil,
              !source.isEmpty, source.count <= 512,
              source.rangeOfCharacter(from: .controlCharacters) == nil,
              key.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil,
              !["__proto__", "constructor", "prototype"].contains(key),
              !data.keys.contains(where: { ["__proto__", "constructor", "prototype"].contains($0) }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        if let target = data[key] {
            guard case let .object(fields) = target,
                  !["decision", "feedback", "comments", "previewId", "requestId", "idempotencyKey"]
                    .contains(where: { fields[$0] != nil }) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
        }
    }

    func event(review: [String: Any]) throws -> [String: Any] {
        try validate()
        let encoded = try JSONEncoder().encode(data)
        var envelope = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let key = responseKey ?? "review"
        guard let decision = review["decision"] as? String else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let comments = review["comments"] as? [[String: Any]] ?? []
        var response = envelope[key] as? [String: Any] ?? [:]
        response["decision"] = decision
        response["feedback"] = (review["feedback"] as? String) ?? comments.compactMap { $0["text"] as? String }.joined(separator: "\n")
        response["comments"] = comments
        for field in ["previewId", "requestId", "idempotencyKey"] {
            response[field] = review[field]
        }
        envelope[key] = response
        return ["type": type, "source": source, "data": envelope]
    }
}

struct MarkcutReviewComment: Codable, Equatable {
    let sceneId: String?
    let timeSeconds: Double
    let text: String
    let scope: String
    var sceneName: String? = nil
}

/// Local draft comments keyed by the compiled scene identity. No server draft storage.
struct MarkcutReviewCommentDraft: Equatable {
    var overall = ""
    private(set) var scenes: [String: MarkcutReviewComment] = [:]

    var sceneCount: Int { scenes.count }
    var hasComments: Bool { !comments.isEmpty }

    func text(for position: MarkcutPlaybackPosition?) -> String {
        guard let id = position?.sceneID else { return "" }
        return scenes[id]?.text ?? ""
    }

    mutating func setSceneText(_ text: String, at position: MarkcutPlaybackPosition?) {
        guard let position, let id = position.sceneID, !id.isEmpty else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            scenes.removeValue(forKey: id)
            return
        }
        var comment = MarkcutReviewComment(sceneId: id, timeSeconds: position.sceneStart,
                                            text: text, scope: "scene")
        comment.sceneName = position.sceneName
        scenes[id] = comment
    }

    var comments: [MarkcutReviewComment] {
        var result: [MarkcutReviewComment] = []
        let overallText = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overallText.isEmpty {
            result.append(MarkcutReviewComment(sceneId: nil, timeSeconds: 0,
                                                text: overallText, scope: "overall"))
        }
        for comment in scenes.values.sorted(by: { ($0.timeSeconds, $0.sceneId ?? "") < ($1.timeSeconds, $1.sceneId ?? "") }) {
            var trimmed = MarkcutReviewComment(sceneId: comment.sceneId, timeSeconds: comment.timeSeconds,
                                                text: comment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                scope: "scene")
            trimmed.sceneName = comment.sceneName
            result.append(trimmed)
        }
        return result
    }
}

struct MarkcutReviewRequest: Codable, Identifiable, Equatable {
    let id: String
    let contentHash: String
    let revisionID: String
    let title: String
    let subtitle: String?
    let mode: String?
    let customTitle: Bool?
    let groupID: String?
    let groupTitle: String?
    let jobID: String?
    let delivery: String?
    let eventTemplate: MarkcutReviewEventTemplate?
    let previewID: String?
    let ownerCallbackTool: String?
    let ownerThreadID: String?
    let playerURL: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, contentHash, mediaHash, title, subtitle, mode, customTitle, groupTitle, delivery, eventTemplate, createdAt
        case previewID = "previewId"
        case revisionID = "revisionId"
        case groupID = "groupId"
        case jobID = "jobId"
        case ownerCallbackTool, ownerThreadID = "ownerThreadId", playerURL = "playerUrl"
    }

    init(id: String, contentHash: String, revisionID: String, title: String,
         subtitle: String? = nil, mode: String? = nil, customTitle: Bool? = nil, groupID: String? = nil, groupTitle: String? = nil, jobID: String? = nil,
         delivery: String? = nil, eventTemplate: MarkcutReviewEventTemplate? = nil,
         previewID: String? = nil, ownerCallbackTool: String? = nil, ownerThreadID: String? = nil,
         playerURL: String? = nil, createdAt: String? = nil) throws {
        guard UUID(uuidString: id) != nil,
              contentHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !revisionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mode.map({ $0 == "questions" }) ?? true,
              delivery.map({ $0 == "text" || $0 == "event" }) ?? true,
              (delivery == "event" ? eventTemplate != nil : eventTemplate == nil),

              ownerCallbackTool.map({ $0 == "chatgpt" || $0 == "review.feedback" || $0.hasSuffix(".review.feedback") }) ?? true,
              ownerThreadID.map({ $0.range(of: "^[A-Za-z0-9_-]{8,160}$", options: .regularExpression) != nil }) ?? true,
              (ownerCallbackTool != "chatgpt" || ownerThreadID != nil),
              playerURL.map({ URL(string: $0)?.scheme == "https" }) ?? true else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try eventTemplate?.validate()
        self.delivery = delivery
        self.eventTemplate = eventTemplate
        self.previewID = previewID
        self.id = id
        self.contentHash = contentHash
        // Event mode has no business revision: use transport request UUID for UI identity.
        self.revisionID = delivery == "event" ? id : revisionID
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.customTitle = customTitle
        self.groupID = groupID
        self.groupTitle = groupTitle
        self.jobID = jobID
        self.ownerCallbackTool = ownerCallbackTool
        self.ownerThreadID = ownerThreadID
        self.playerURL = playerURL
        self.createdAt = createdAt
    }

    // JSONDecoder does not call the memberwise validating initializer.
    // Validate untrusted MCP requests even when decoded from wire JSON.
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let isEvent = (try fields.decodeIfPresent(String.self, forKey: .delivery)) == "event"
        if isEvent && (fields.contains(.contentHash) || fields.contains(.revisionID)) {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let eventTemplate = try fields.decodeIfPresent(MarkcutReviewEventTemplate.self, forKey: .eventTemplate)
                try self.init(
            id: fields.decode(String.self, forKey: .id),
            contentHash: fields.decode(String.self, forKey: isEvent ? .mediaHash : .contentHash),
            revisionID: isEvent ? (try fields.decode(String.self, forKey: .id)) : fields.decode(String.self, forKey: .revisionID),
            title: fields.decode(String.self, forKey: .title),
            subtitle: fields.decodeIfPresent(String.self, forKey: .subtitle),
            mode: fields.decodeIfPresent(String.self, forKey: .mode),
            customTitle: fields.decodeIfPresent(Bool.self, forKey: .customTitle),
            groupID: fields.decodeIfPresent(String.self, forKey: .groupID),
            groupTitle: fields.decodeIfPresent(String.self, forKey: .groupTitle),
            jobID: fields.decodeIfPresent(String.self, forKey: .jobID),
            delivery: fields.decodeIfPresent(String.self, forKey: .delivery),
            eventTemplate: eventTemplate,
            previewID: fields.decodeIfPresent(String.self, forKey: .previewID),
            ownerCallbackTool: fields.decodeIfPresent(String.self, forKey: .ownerCallbackTool),
            ownerThreadID: fields.decodeIfPresent(String.self, forKey: .ownerThreadID),
            playerURL: fields.decodeIfPresent(String.self, forKey: .playerURL),
            createdAt: fields.decodeIfPresent(String.self, forKey: .createdAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(subtitle, forKey: .subtitle)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        if delivery == "event" {
            try c.encode(contentHash, forKey: .mediaHash)
        } else {
            try c.encode(contentHash, forKey: .contentHash)
            try c.encode(revisionID, forKey: .revisionID)
        }
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(groupTitle, forKey: .groupTitle)
        try c.encodeIfPresent(jobID, forKey: .jobID)
        try c.encodeIfPresent(delivery, forKey: .delivery)
        try c.encodeIfPresent(eventTemplate, forKey: .eventTemplate)
        try c.encodeIfPresent(previewID, forKey: .previewID)
        try c.encodeIfPresent(ownerCallbackTool, forKey: .ownerCallbackTool)
        try c.encodeIfPresent(ownerThreadID, forKey: .ownerThreadID)
        try c.encodeIfPresent(playerURL, forKey: .playerURL)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    var effectiveDelivery: String { delivery ?? "text" }
    var canDeliver: Bool { delivery == "event" ? eventTemplate != nil : (ownerThreadID != nil || ownerCallbackTool != nil) }

    var groupingValue: [String: Any] {
        var value: [String: Any] = ["id": id, "title": title, "status": "ready",
                                    "reviewActionable": canDeliver, "delivery": effectiveDelivery]
        if let subtitle { value["subtitle"] = subtitle }
        if delivery == "event" { value["mediaHash"] = contentHash }
        else { value["revisionId"] = revisionID; value["contentHash"] = contentHash }
        if let mode { value["mode"] = mode }
        if let customTitle { value["customTitle"] = customTitle }
        if let groupID { value["videoGroupKey"] = groupID }
        if let groupTitle { value["videoGroupTitle"] = groupTitle }
        if let jobID {
            var relay: [String: Any] = ["jobId": jobID]
            if let groupID {
                let parts = groupID.split(separator: "/").map(String.init)
                if parts.count == 4, parts[0] == "job", parts[1] == jobID,
                   parts[2] == "task", !parts[3].isEmpty {
                    relay["taskId"] = parts[3]
                }
            }
            value["relayCorrelations"] = [relay]
        }
        if let playerURL { value["playerUrl"] = playerURL }
        if let createdAt { value["createdAt"] = createdAt }
        return value
    }
}

struct MarkcutReviewFeedback: Codable, Equatable, Identifiable {
    let requestId: String
    let decision: MarkcutReviewChoice
    let feedback: String
    let idempotencyKey: String
    let comments: [MarkcutReviewComment]?

    init(requestId: String, decision: MarkcutReviewChoice, feedback: String, idempotencyKey: String,
         comments: [MarkcutReviewComment]? = nil) {
        self.requestId = requestId
        self.decision = decision
        self.feedback = feedback
        self.idempotencyKey = idempotencyKey
        self.comments = comments
    }

    func reviewResult(request: MarkcutReviewRequest) -> [String: Any] {
        let resolvedComments: [MarkcutReviewComment] = comments ?? (
            request.mode == "questions" || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] :
            [MarkcutReviewComment(sceneId: nil, timeSeconds: 0, text: feedback, scope: "overall")])
        var result: [String: Any] = ["requestId": request.id,
                "previewId": request.previewID ?? request.revisionID,
                "decision": decision.rawValue,
                "feedback": feedback,
                "comments": resolvedComments.map { comment in
                    ["sceneId": comment.sceneId as Any? ?? NSNull(),
                     "sceneName": comment.sceneName as Any? ?? NSNull(),
                     "timeSeconds": comment.timeSeconds, "text": comment.text, "scope": comment.scope] as [String: Any]
                },
                "idempotencyKey": idempotencyKey]
        if request.delivery != "event" { result["revisionId"] = request.revisionID; result["contentHash"] = request.contentHash }
        return result
    }
    var id: String { requestId }

    static func chatGPTMessage(request: MarkcutReviewRequest, feedback: MarkcutReviewFeedback) -> String {
        // Structured evidence for the owning thread to process, with an idempotency
        // key so revisiting a queue turn is not a second human decision.
        """
        Neo Mobile Markcut review feedback (user-submitted)
        request_id: \(request.id)
        revision_id: \(request.revisionID)
        content_hash: \(request.contentHash)
        idempotency_key: \(feedback.idempotencyKey)
        decision: \(feedback.decision.rawValue)
        feedback: \(feedback.feedback)
        review_result: \(reviewResultJSON(request: request, feedback: feedback))
        Process this decision for the exact revision above. Do not assume approval for later revisions.
        """
    }

    private static func reviewResultJSON(request: MarkcutReviewRequest, feedback: MarkcutReviewFeedback) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: feedback.reviewResult(request: request), options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func requireChatGPTReceipt(_ receipt: [String: Any]) throws {
        // Async means accepted into the platform's durable delivery queue;
        // it does NOT prove the thread has finished acting on the review.
        let inner = receipt["result"] as? [String: Any] ?? receipt
        guard inner["status"] as? String == "submitted",
              inner["mode"] as? String == "new-turn" else {
            throw NSError(domain: "MarkcutReviewFeedback", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "ChatGPT did not confirm queued delivery"])
        }
    }

    static func requireAcknowledgement(_ result: [String: Any]) throws {
        guard result["acknowledged"] as? Bool == true else {
            throw NSError(domain: "MarkcutReviewFeedback", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Owner tool did not acknowledge feedback"])
        }
    }
}

struct MarkcutReviewCompleted: Codable, Equatable {
    let feedback: MarkcutReviewFeedback
    let submittedAt: Date
}

@MainActor
final class MarkcutReviewInboxStore: ObservableObject {
    static let shared = MarkcutReviewInboxStore()
    private let requestsKey = "markcut.review.inbox.v2"
    private let feedbackKey = "markcut.review.feedback.v2"
    private let completedKey = "markcut.review.completed.v1"
    private let dismissedKey = "markcut.review.dismissed.v1"
    private let latestGroupKey = "markcut.review.latest-group.v1"
    private var latestGroupRequestIDs: [String: String]
    private var dismissedIDs: [String]
    private let defaults: UserDefaults
    @Published private(set) var requests: [MarkcutReviewRequest]
    @Published private(set) var feedbackQueue: [MarkcutReviewFeedback]
    @Published private(set) var completed: [String: MarkcutReviewCompleted]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissedIDs = defaults.stringArray(forKey: dismissedKey) ?? []
        requests = (try? JSONDecoder().decode([MarkcutReviewRequest].self,
            from: defaults.data(forKey: requestsKey) ?? Data())) ?? []
        feedbackQueue = (try? JSONDecoder().decode([MarkcutReviewFeedback].self,
            from: defaults.data(forKey: feedbackKey) ?? Data())) ?? []
        completed = (try? JSONDecoder().decode([String: MarkcutReviewCompleted].self,
            from: defaults.data(forKey: completedKey) ?? Data())) ?? [:]
        latestGroupRequestIDs = defaults.dictionary(forKey: latestGroupKey) as? [String: String] ?? [:]
        // On upgrade, recover the newest request for each group without losing
        // tombstones that already outlived their acknowledged requests.
        for request in requests {
            if let groupID = request.groupID, latestGroupRequestIDs[groupID] == nil {
                latestGroupRequestIDs[groupID] = request.id
            }
        }
        defaults.set(latestGroupRequestIDs, forKey: latestGroupKey)
    }

    @discardableResult
    func accept(_ request: MarkcutReviewRequest, notify: Bool = true) -> Bool {
        guard !dismissedIDs.contains(request.id) else { return false }
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            // Enrich existing iPhone rows after the Master adds timestamps;
            // a later sync must not leave old local rows permanently unsorted.
            if requests[index].createdAt == nil && request.createdAt != nil {
                requests[index] = request
                saveRequests()
            }
            return false
        }
        requests.insert(request, at: 0)
        if let groupID = request.groupID {
            latestGroupRequestIDs[groupID] = request.id
            defaults.set(latestGroupRequestIDs, forKey: latestGroupKey)
        }
        saveRequests()
        if notify { notifyForNewRequest(request) }
        return true
    }

    func remove(_ id: String) {
        guard !feedbackQueue.contains(where: { $0.requestId == id }) else { return }
        requests.removeAll { $0.id == id }
        completed.removeValue(forKey: id)
        saveCompleted()
        rememberDismissed(id)
        saveRequests()
        clearNotifications(id)
    }

    func queue(_ feedback: MarkcutReviewFeedback) {
        guard !feedbackQueue.contains(where: { $0.requestId == feedback.requestId }) else { return }
        feedbackQueue.append(feedback)
        saveFeedback()
    }

    func acknowledge(_ feedback: MarkcutReviewFeedback) {
        // Transport accepted the exact user decision. Keep the review and media
        // identity as a local, read-only record until the user deletes it.
        guard requests.contains(where: { $0.id == feedback.requestId }) else { return }
        completed[feedback.requestId] = MarkcutReviewCompleted(feedback: feedback, submittedAt: Date())
        feedbackQueue.removeAll { $0.id == feedback.id }
        saveCompleted()
        saveFeedback()
        clearNotifications(feedback.requestId)
    }

    func request(id: String) -> MarkcutReviewRequest? { requests.first { $0.id == id } }
    func hasSavedOrDismissed(_ id: String) -> Bool {
        requests.contains(where: { $0.id == id }) || dismissedIDs.contains(id)
    }

    // A newer accepted review for the same video supersedes older revisions.
    // Keep historical requests visible, but never let them submit as current.
    func isCurrent(_ request: MarkcutReviewRequest) -> Bool {
        guard let groupID = request.groupID else { return true }
        return latestGroupRequestIDs[groupID] == request.id
    }

    var groupedSessions: [[String: Any]] {
        requests.map { request in
            var item = request.groupingValue
            if let recorded = completed[request.id] {
                item["status"] = "decided"
                item["decision"] = ["decision": recorded.feedback.decision.rawValue,
                                    "feedback": recorded.feedback.feedback,
                                    "submittedAt": ISO8601DateFormatter().string(from: recorded.submittedAt)]
            } else if !isCurrent(request) { item["status"] = "superseded" }
            return item
        }
    }

    private func rememberDismissed(_ id: String) {
        // Client-owned, bounded dedup tombstones prevent a delayed APNs alert
        // or repeat delivery from resurrecting a completed review.
        dismissedIDs.removeAll { $0 == id }
        dismissedIDs.append(id)
        if dismissedIDs.count > 512 { dismissedIDs.removeFirst(dismissedIDs.count - 512) }
        defaults.set(dismissedIDs, forKey: dismissedKey)
    }

    private func clearNotifications(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["markcut-review-\(id)"])
        center.removeDeliveredNotifications(withIdentifiers: ["markcut-review-\(id)"])
        Task { await ReviewPushCoordinator.shared.clearDeliveredReview(id) }
    }

    private func saveRequests() {
        if let data = try? JSONEncoder().encode(requests) { defaults.set(data, forKey: requestsKey) }
    }

    private func saveFeedback() {
        if let data = try? JSONEncoder().encode(feedbackQueue) { defaults.set(data, forKey: feedbackKey) }
    }

    private func saveCompleted() {
        if let data = try? JSONEncoder().encode(completed) { defaults.set(data, forKey: completedKey) }
    }

    private func notifyForNewRequest(_ request: MarkcutReviewRequest) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = request.canDeliver ? "Video ready for review" : "Video preview ready"
            content.body = request.title
            content.sound = .default
            content.userInfo = ["reviewRequestId": request.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "markcut-review-\(request.id)",
                                                                           content: content, trigger: nil))
        }
    }
}
