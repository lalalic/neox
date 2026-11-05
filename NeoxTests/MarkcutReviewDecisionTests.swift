import XCTest
@testable import NeoxApp

final class MarkcutReviewDecisionTests: XCTestCase {
    @MainActor
    func testReviewRequestPersistenceReplayAndRemovalArePhoneOwned() throws {
        let suite = "MarkcutReviewInboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = try MarkcutReviewRequest(id: "00000000-0000-4000-8000-000000000001",
            contentHash: String(repeating: "a", count: 64), revisionID: "rev-2", title: "Cut review",
            groupID: "creative-1", groupTitle: "Creative", ownerCallbackTool: "vlog.review.feedback")
        let store = MarkcutReviewInboxStore(defaults: defaults)

        let firstAccepted = store.accept(request, notify: false)
        let replayAccepted = store.accept(request, notify: false)
        let restored = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertTrue(firstAccepted)
        XCTAssertFalse(replayAccepted, "replayed request UUID must be idempotent")
        XCTAssertEqual(restored, [request])

        store.remove(request.id)
        XCTAssertFalse(store.accept(request, notify: false), "late APNs must not resurrect a removed review")
        let afterRemoval = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertTrue(afterRemoval.isEmpty,
                      "local refresh/relaunch must not restore removed rows")
    }

    @MainActor
    func testRequestValidationAndToolRegistration() throws {
        XCTAssertThrowsError(try MarkcutReviewRequest(id: "not-uuid", contentHash: String(repeating: "a", count: 64),
            revisionID: "rev", title: "Cut"))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString, contentHash: String(repeating: "A", count: 64),
            revisionID: "rev", title: "Cut"))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString, contentHash: String(repeating: "a", count: 64),
            revisionID: " ", title: "Cut"))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "a", count: 64), revisionID: "rev", title: "Unsafe",
            ownerCallbackTool: "neo.shell.exec"))
        let invalidJSON = """
            {"id":"not-a-uuid","contentHash":"\(String(repeating: "a", count: 64))",
             "revisionId":"rev","title":"Invalid"}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(MarkcutReviewRequest.self,
            from: Data(invalidJSON.utf8)))
        let unsafeCallbackJSON = """
            {"id":"\(UUID().uuidString)","contentHash":"\(String(repeating: "a", count: 64))",
             "revisionId":"rev","title":"Invalid","ownerCallbackTool":"neo.shell.exec"}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(MarkcutReviewRequest.self,
            from: Data(unsafeCallbackJSON.utf8)))
        let server = MCPServer()
        server.register(tools: MarkcutReviewRequestTool.tools())
        let registeredTools = server.toolNames
        XCTAssertEqual(registeredTools, ["review.request"])
    }

    @MainActor
    func testChatGPTOwnerRoutingAndReceiptRequirements() throws {
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "c", count: 64), revisionID: "rev-3", title: "Test",
            ownerCallbackTool: "chatgpt", ownerThreadID: "6ae92acc-cd28-83ea-8dc6-224653c9b433")
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .changesRequested,
            feedback: "Needs a transition", idempotencyKey: "test-key-1")
        let message = MarkcutReviewFeedback.chatGPTMessage(request: request, feedback: feedback)
        XCTAssertTrue(message.contains(request.id))
        XCTAssertTrue(message.contains(request.contentHash))
        XCTAssertTrue(message.contains("test-key-1"))
        XCTAssertTrue(message.contains("Needs a transition"))
        XCTAssertNoThrow(try MarkcutReviewFeedback.requireChatGPTReceipt([
            "status": "submitted", "mode": "new-turn"]))
        XCTAssertThrowsError(try MarkcutReviewFeedback.requireChatGPTReceipt([
            "status": "submitted", "mode": "new-thread"]))
        XCTAssertThrowsError(try MarkcutReviewFeedback.requireChatGPTReceipt([
            "status": "queued", "mode": "new-turn"]))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "c", count: 64), revisionID: "rev", title: "No thread",
            ownerCallbackTool: "chatgpt"))
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(MarkcutReviewRequest.self, from: encoded), request)
    }

    @MainActor
    func testAPNsPayloadDecodingRejectsInvalidRequests() throws {
        let valid: [AnyHashable: Any] = ["neoReview": [
            "id": UUID().uuidString, "contentHash": String(repeating: "a", count: 64),
            "revisionId": "rev-1", "title": "Push review", "ownerCallbackTool": "chatgpt",
            "ownerThreadId": "6ae92acc-cd28-83ea-8dc6-224653c9b433"
        ]]
        XCTAssertEqual(ReviewPushCoordinator.decodeReview(valid)?.title, "Push review")
        XCTAssertNil(ReviewPushCoordinator.decodeReview(["neoReview": ["id": "bad"]]))
        XCTAssertNil(ReviewPushCoordinator.decodeReview(["unrelated": "data"]))
    }

    @MainActor
    func testFeedbackRemainsQueuedWithoutOwnerAcknowledgement() throws {
        let suite = "MarkcutReviewFeedbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "b", count: 64), revisionID: "rev-1", title: "Review",
            ownerCallbackTool: "vlog.review.feedback")
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .approved,
            feedback: "", idempotencyKey: UUID().uuidString)
        let store = MarkcutReviewInboxStore(defaults: defaults)
        store.accept(request, notify: false)
        store.queue(feedback)

        XCTAssertThrowsError(try MarkcutReviewFeedback.requireAcknowledgement(["accepted": true]))
        let queuedFeedback = MarkcutReviewInboxStore(defaults: defaults).feedbackQueue
        let pendingRequests = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertEqual(queuedFeedback, [feedback])
        XCTAssertEqual(pendingRequests, [request])
        XCTAssertNoThrow(try MarkcutReviewFeedback.requireAcknowledgement(["acknowledged": true]))
        store.acknowledge(feedback)
        let afterAcknowledgement = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertTrue(afterAcknowledgement.isEmpty)
    }

    @MainActor
    func testEventDeliveryTemplateValidationAndReviewResultSerialization() throws {
        let template = MarkcutReviewEventTemplate(type: "markcut.review.submitted",
            source: "job/j123/task/producer/execution/e456",
            data: ["correlation": .object(["jobId": .string("j123")])])
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "b", count: 64), revisionID: "rev-42",
            title: "Review scene", delivery: "event", eventTemplate: template,
            previewID: "preview-42")
        let comment = MarkcutReviewComment(sceneId: "intro", timeSeconds: 4.25,
            text: "Remove second pause", scope: "spot")
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .changesRequested,
            feedback: "Remove second pause", idempotencyKey: "stable-retry-key", comments: [comment])
        let result = feedback.reviewResult(request: request)
        let event = try template.event(review: result)
        XCTAssertEqual(event["source"] as? String, template.source)
        XCTAssertEqual(event["type"] as? String, "markcut.review.submitted")
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        XCTAssertEqual((data["correlation"] as? [String: String])?["jobId"], "j123")
        let review = try XCTUnwrap(data["review"] as? [String: Any])
        XCTAssertEqual(review["previewId"] as? String, "preview-42")
        XCTAssertEqual(review["contentHash"] as? String, request.contentHash)
        XCTAssertEqual(review["idempotencyKey"] as? String, "stable-retry-key")
        let comments = try XCTUnwrap(review["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.first?["sceneId"] as? String, "intro")
        XCTAssertEqual(comments.first?["timeSeconds"] as? Double, 4.25)
        let restored = try JSONDecoder().decode(MarkcutReviewRequest.self,
            from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.eventTemplate, template)
        XCTAssertTrue(restored.canDeliver)
        let relayTemplate = MarkcutReviewEventTemplate(type: "task.interactive_decision",
            source: "job/j123/task/producer/execution/e456",
            data: ["interactive": .object([
                "jobId": .string("j123"), "taskId": .string("producer"),
                "executionId": .string("e456"), "invocationId": .string("video-preview-42")
            ])])
        let relayEvent = try relayTemplate.event(review: result)
        XCTAssertEqual(relayEvent["type"] as? String, "task.interactive_decision")
        let relayData = try XCTUnwrap(relayEvent["data"] as? [String: Any])
        let interactive = try XCTUnwrap(relayData["interactive"] as? [String: Any])
        XCTAssertEqual(interactive["revision"] as? String, request.contentHash)
        XCTAssertEqual(interactive["revisionId"] as? String, request.revisionID)
        XCTAssertEqual(interactive["decision"] as? String, "changes_requested")
        XCTAssertEqual(interactive["feedback"] as? String, "Remove second pause")
        XCTAssertEqual(interactive["idempotencyKey"] as? String, "stable-retry-key")
        XCTAssertEqual((interactive["comments"] as? [[String: Any]])?.first?["sceneId"] as? String, "intro")
        XCTAssertThrowsError(try MarkcutReviewEventTemplate(
            type: "task.interactive_decision", source: relayTemplate.source,
            data: ["interactive": .object([
                "jobId": .string("j123"), "taskId": .string("producer"), "executionId": .string("e456"),
                "invocationId": .string("video-preview-42"), "decision": .string("approved")
            ])]).validate())
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: request.contentHash, revisionID: "rev", title: "Bad",
            delivery: "event", eventTemplate: MarkcutReviewEventTemplate(
                type: "task.completed", source: template.source, data: [:])))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: request.contentHash, revisionID: "rev", title: "Bad",
            delivery: "event", eventTemplate: nil))
    }

    @MainActor
    func testEventFeedbackRetryPreservesRequestAndIdempotencyAcrossRelaunch() throws {
        let suite = "MarkcutReviewEventRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "c", count: 64), revisionID: "r8", title: "Review",
            delivery: "event", eventTemplate: MarkcutReviewEventTemplate(
                type: "markcut.review.submitted",
                source: "job/j8/task/review/execution/e8", data: [:]))
        let queued = MarkcutReviewFeedback(requestId: request.id, decision: .approved,
            feedback: "", idempotencyKey: "retry-key-preserved")
        let inbox = MarkcutReviewInboxStore(defaults: defaults)
        XCTAssertTrue(inbox.accept(request, notify: false))
        inbox.queue(queued)
        let restored = MarkcutReviewInboxStore(defaults: defaults)
        XCTAssertEqual(restored.requests, [request])
        XCTAssertEqual(restored.feedbackQueue, [queued])
        XCTAssertEqual(restored.feedbackQueue[0].reviewResult(request: request)["idempotencyKey"] as? String,
                       "retry-key-preserved")
        XCTAssertEqual(restored.feedbackQueue[0].reviewResult(request: request)["comments"] as? [[String: String]], [])
        restored.acknowledge(queued)
        XCTAssertEqual(MarkcutReviewInboxStore(defaults: defaults).requests.count, 0)
    }

    @MainActor
    func testNewVideoRevisionMakesOldMobileRequestReadonly() throws {
        let suite = "MarkcutReviewStale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = MarkcutReviewInboxStore(defaults: defaults)
        let old = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "1", count: 64), revisionID: "r1",
            title: "Cut v1", groupID: "same-video", ownerCallbackTool: "review.feedback")
        let new = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "2", count: 64), revisionID: "r2",
            title: "Cut v2", groupID: "same-video", ownerCallbackTool: "review.feedback")
        XCTAssertTrue(inbox.accept(old, notify: false))
        XCTAssertTrue(inbox.isCurrent(old))
        XCTAssertTrue(inbox.accept(new, notify: false))
        XCTAssertFalse(inbox.isCurrent(old))
        XCTAssertTrue(inbox.isCurrent(new))
        // Acknowledging the latest review must not reactivate an older revision.
        inbox.acknowledge(MarkcutReviewFeedback(requestId: new.id,
            decision: .approved, feedback: "", idempotencyKey: "ack-new"))
        XCTAssertFalse(inbox.isCurrent(old))
        XCTAssertFalse(MarkcutReviewInboxStore(defaults: defaults).isCurrent(old))
        XCTAssertEqual(inbox.groupedSessions.first(where: {$0["id"] as? String == old.id})?["status"] as? String,
                       "superseded")
    }

    func testReviewGroupingKeepsJobSessionsTogetherAndSeparatesJobs() {
        let sessions: [[String: Any]] = [
            ["id":"a", "label":"video-a-v1", "status":"ready", "createdAt":"2026-11-01T10:00:00Z",
             "relayCorrelations":[["jobId":"job-one", "taskId":"task-a"]]],
            ["id":"b", "label":"video-a-v2", "status":"superseded", "createdAt":"2026-11-01T11:00:00Z",
             "relayCorrelations":[["jobId":"job-one", "taskId":"task-a"]]],
            ["id":"c", "label":"video-a-v3", "status":"ready", "createdAt":"2026-11-01T12:00:00Z",
             "relayCorrelations":[["jobId":"job-two", "taskId":"task-b"]]]
        ]

        let groups = MarkcutReviewGrouping.groups(from: sessions)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first(where: { $0.jobID == "job-one" })?.sessions.map(\.reviewSessionID), ["b", "a"])
        XCTAssertEqual(groups.first(where: { $0.jobID == "job-one" })?.pendingCount, 1)
        XCTAssertEqual(groups.first(where: { $0.jobID == "job-one" })?.title, "Job #job-one")
    }

    func testSessionWithMultipleRelayCorrelationsIsVisibleInEachCorrelatedJob() {
        let session: [String: Any] = ["id":"shared-session", "label":"clip", "status":"ready",
            "relayCorrelations":[["jobId":"job-one"], ["jobId":"job-two"]]]

        let groups = MarkcutReviewGrouping.groups(from: [session])

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.sessions.map(\.reviewSessionID) == ["shared-session"] })
    }

    func testOpaqueVideoGroupKeysKeepRevisionsTogetherWithoutExposingPaths() {
        let sessions: [[String: Any]] = [
            ["id":"a", "videoGroupKey":"source-one", "videoGroupTitle":"v1", "status":"ready"],
            ["id":"b", "videoGroupKey":"source-one", "videoGroupTitle":"v1", "status":"superseded"],
            ["id":"c", "videoGroupKey":"source-two", "videoGroupTitle":"v2", "status":"ready"]
        ]
        let groups = MarkcutReviewGrouping.groups(from: sessions)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first(where: { $0.id == "video:source-one" })?.sessions.count, 2)
        XCTAssertEqual(groups.first(where: { $0.id == "video:source-one" })?.title, "V1")
        XCTAssertEqual(groups.first(where: { $0.id == "video:source-one" })?.pendingCount, 1)
    }

    func testDatedCreativeJobGetsCompactHeader() {
        let groups = MarkcutReviewGrouping.groups(from: [
            ["id":"a", "videoGroupKey":"run", "videoGroupTitle":"2026-11-02-rsboost-backup", "status":"ready"]
        ])
        XCTAssertEqual(groups.first?.title, "Rsboost Backup · 11/02")
    }

    func testFallbackGroupsByParentAndKeepsGenericBasenamesWithoutParentSeparate() {
        let sessions: [[String: Any]] = [
            ["id":"a", "path":"/work/creative-a/video.md", "status":"ready"],
            ["id":"b", "path":"/work/creative-a/video.md", "status":"superseded"],
            ["id":"c", "label":"video.md", "status":"ready"],
            ["id":"d", "label":"video.md", "status":"ready"]
        ]

        let groups = MarkcutReviewGrouping.groups(from: sessions)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first(where: { $0.id == "parent:work/creative-a" })?.sessions.count, 2)
        XCTAssertNotEqual(groups.first(where: { $0.sessions.contains(where: { $0.reviewSessionID == "c" }) })?.id,
                          groups.first(where: { $0.sessions.contains(where: { $0.reviewSessionID == "d" }) })?.id)
    }
}
