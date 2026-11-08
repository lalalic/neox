import XCTest
@testable import NeoxApp

@MainActor
final class ChatGatewayOutboxTests: XCTestCase {
    func testQueuePersistsUntilAcknowledgedAndRetainsIdentityAcrossRestart() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-outbox-" + UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = ChatGatewayOutbox(file: file)
        let saved = try first.enqueue("Message while offline")
        XCTAssertEqual(first.messages.count, 1)

        let restored = ChatGatewayOutbox(file: file)
        XCTAssertEqual(restored.messages.first?.id, saved.id)
        XCTAssertEqual(restored.messages.first?.text, saved.text)

        try restored.acknowledge(saved.id)
        XCTAssertTrue(ChatGatewayOutbox(file: file).messages.isEmpty)
    }

    func testTwoMessagesKeepDistinctIdempotencyKeys() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-outbox-" + UUID().uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = ChatGatewayOutbox(file: file)
        let first = try outbox.enqueue("first")
        let second = try outbox.enqueue("second")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(outbox.messages.map(\.text), ["first", "second"])
        try outbox.acknowledge(first.id)
        XCTAssertEqual(outbox.messages.map(\.id), [second.id])
    }
}
