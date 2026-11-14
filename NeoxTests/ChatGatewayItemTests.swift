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

    func testSmartMessageTimesAndFractionalISO8601() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = ISO8601DateFormatter().date(from: "2026-11-13T20:00:00Z")!
        func label(_ timestamp: String) throws -> String {
            let item = try ChatGatewayItem(wire: ["id":"owner:sample", "kind":"owner",
                "text":"Message", "at":timestamp])
            return item.smartDateLabel(relativeTo: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        XCTAssertEqual(try label("2026-11-13T19:01:00.000Z"), "7:01 PM")
        XCTAssertEqual(try label("2026-11-12T09:30:00Z"), "Yesterday · 9:30 AM")
        XCTAssertEqual(try label("2026-11-11T12:00:00Z"), "Wednesday · 12:00 PM")
        XCTAssertEqual(try label("2026-10-20T08:00:00Z"), "Oct 20 · 8:00 AM")
        XCTAssertEqual(try label("2025-11-13T08:00:00Z"), "Nov 13, 2025 · 8:00 AM")
    }

    func testMarkdownMermaidAndMarkcutMessageParts() {
        let hash = String(repeating: "a", count: 64)
        let body = """
        **Summary**

        ```mermaid
        flowchart TD
        A[Input] --> B[Output]
        ```

        [Open Markcut preview](markcut://preview/\(hash))
        """
        let parts = ChatMessageMarkup.parse(body)
        XCTAssertTrue(parts.contains(.mermaid("flowchart TD\nA[Input] --> B[Output]")))
        XCTAssertTrue(parts.contains(.markcut(hash)))
        XCTAssertTrue(parts.contains(where: {
            if case .markdown(let source) = $0 { return source.contains("**Summary**") }
            return false
        }))
        XCTAssertEqual(ChatMessageMarkup.parse("```markcut\ncontentHash: \(hash)\n```"), [.markcut(hash)])
        XCTAssertEqual(ChatMessageMarkup.parse("```markcut\nsource: video.md\n```"),
                       [.markdown("```markcut\nsource: video.md\n```")])
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

