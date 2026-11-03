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
