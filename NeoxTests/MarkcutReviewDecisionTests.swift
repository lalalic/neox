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
}
