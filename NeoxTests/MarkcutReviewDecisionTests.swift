import XCTest
@testable import NeoxApp

final class MarkcutReviewDecisionTests: XCTestCase {
    func testOfflineQueueRoundTripsExactRevisionAndIdempotencyKey() throws {
        let suite = "MarkcutReviewDecisionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let decision = try MarkcutReviewDecision(sessionID: "00000000-0000-4000-8000-000000000001",
            contentHash: String(repeating: "a", count: 64), choice: .changesRequested,
            comments: [MarkcutReviewComment(scope: "overall", text: "Tighten the opening")],
            idempotencyKey: "mobile-action-0001")

        MarkcutReviewDecision.saveQueue([decision.idempotencyKey: decision], to: defaults)
        let restored = MarkcutReviewDecision.loadQueue(from: defaults)[decision.idempotencyKey]

        XCTAssertEqual(restored, decision)
        XCTAssertEqual(decision.mcpArguments["contentHash"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(decision.mcpArguments["decision"] as? String, "changes_requested")
    }

    func testOnlyValidApprovalOrFeedbackDecisionCanBeQueued() {
        XCTAssertThrowsError(try MarkcutReviewDecision(sessionID: "not-a-session",
            contentHash: String(repeating: "b", count: 64), choice: .approved, comments: []))
        XCTAssertThrowsError(try MarkcutReviewDecision(sessionID: "00000000-0000-4000-8000-000000000002",
            contentHash: "old-hash", choice: .approved, comments: []))
        XCTAssertThrowsError(try MarkcutReviewDecision(sessionID: "00000000-0000-4000-8000-000000000002",
            contentHash: String(repeating: "b", count: 64), choice: .changesRequested, comments: []))
        XCTAssertThrowsError(try MarkcutReviewDecision(sessionID: "00000000-0000-4000-8000-000000000002",
            contentHash: String(repeating: "b", count: 64), choice: .approved,
            comments: [MarkcutReviewComment(scope: "overall", text: "comment")]))
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
