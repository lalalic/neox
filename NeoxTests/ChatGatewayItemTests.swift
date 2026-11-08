import XCTest
@testable import NeoxApp

final class ChatGatewayItemTests: XCTestCase {
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

