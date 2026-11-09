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

    func testOriginalBinaryAttachmentSurvivesOutboxRestartAndIsRemovedOnAck() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-binary-" + UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = Data([0x00, 0x89, 0xff, 0xc1, 0x00, 0x01, 0x10])
        let first = ChatGatewayOutbox(file: file)
        let attachment = try first.stage(original, name: "photo.png")
        let message = try first.enqueue("", attachments: [attachment])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)), original)
        let restored = ChatGatewayOutbox(file: file)
        XCTAssertEqual(restored.messages.first?.attachments?.first?.sha256, attachment.sha256)
        XCTAssertEqual(restored.messages.first?.id, message.id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: attachment.path)), original)
        try restored.acknowledge(message.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.path))
    }

    func testLegacyTextOnlyOutboxDecodesWithoutAttachments() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-legacy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("outbox.json")
        let legacy = Data(#"[{"id":"legacy-12345678","text":"old","createdAt":0}]"#.utf8)
        try legacy.write(to: file)
        let restored = ChatGatewayOutbox(file: file)
        XCTAssertEqual(restored.messages.first?.text, "old")
        XCTAssertNil(restored.messages.first?.attachments)
    }
}
