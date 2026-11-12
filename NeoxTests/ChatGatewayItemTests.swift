import XCTest
@testable import NeoxApp

final class ChatGatewayItemTests: XCTestCase {
    @MainActor
    func testLocalChatClearPersistsWithoutDeletingQueuedWork() throws {
        let suite = "NeoChatClear.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = ChatGatewayOutbox(file: directory.appendingPathComponent("outbox.json"))
        try outbox.enqueue("Unsent message", at: Date(timeIntervalSince1970: 1762900000))
        let store = ChatGatewayStore(outbox: outbox, preferences: preferences)
        XCTAssertEqual(store.visibleItems.count, 1)
        store.clearVisibleHistory(at: Date(timeIntervalSince1970: 1762900050))
        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertEqual(store.queued.count, 1, "Clear must not discard unsent work")
        let restored = ChatGatewayStore(outbox: ChatGatewayOutbox(file: directory.appendingPathComponent("outbox.json")),
                                        preferences: preferences)
        XCTAssertTrue(restored.visibleItems.isEmpty)
        XCTAssertEqual(restored.queued.count, 1)
    }

    func testJobEventVisibleWithoutRawPrompt() throws {
        let item = try ChatGatewayItem(wire: [
            "id": "job:123:COMPLETED:now", "kind": "job",
            "text": "Test job", "at": "2026-11-08T15:00:00.000Z",
            "status": "COMPLETED", "jobId": "123", "repository": "example/neo"
        ])
        XCTAssertEqual(item.title, "Job 123 COMPLETED")
        XCTAssertEqual(item.text, "Test job")
    }

    func testReportAndOwnerAreDistinguished() throws {
        let report = try ChatGatewayItem(wire: [
            "id": "report:aaa", "kind": "report",
            "text": "Please check", "at": "2026-11-08T15:00:00.000Z",
            "level": "attention"
        ])
        XCTAssertEqual(report.title, "Orchestrator · Attention")
        let owner = try ChatGatewayItem(wire: [
            "id": "owner:bbb", "kind": "owner",
            "text": "Hello", "at": "2026-11-08T15:00:00.000Z",
            "status": "submitted"
        ])
        XCTAssertEqual(owner.title, "You")
        XCTAssertEqual(owner.status, "submitted")
    }

    func testRejectMalformedGatewayHistory() {
        XCTAssertThrowsError(try ChatGatewayItem(wire: [
            "id": "x", "kind": "unknown", "text": "bad", "at": "2026-11-08"
        ]))
        XCTAssertThrowsError(try ChatGatewayItem(wire: [
            "id": "x", "kind": "job", "text": "missing time"
        ]))
    }
}

