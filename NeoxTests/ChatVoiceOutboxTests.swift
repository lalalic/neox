import Foundation
import XCTest
@testable import NeoxApp

@MainActor
final class ChatVoiceOutboxTests: XCTestCase {
    func testVoiceSubmissionUsesExistingChatOutboxAndPreservesTypedDraft() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-voice-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = ChatGatewayOutbox(file: folder.appendingPathComponent("outbox.json"))
        let history = ChatGatewayHistory(file: folder.appendingPathComponent("history.json"))
        let preferences = UserDefaults(suiteName: "chat-voice-test-" + UUID().uuidString)!
        let store = ChatGatewayStore(outbox: outbox, preferences: preferences, history: history)
        let master = RemoteMCPClient(testEndpoint: "https://127.0.0.1:1", testBearer: "test-only")
        store.draft = "Unsent typed draft"

        let requestID = try XCTUnwrap(store.sendVoiceText("  Hello by voice  ", using: master))
        XCTAssertEqual(outbox.messages.count, 1)
        XCTAssertEqual(outbox.messages[0].id, requestID)
        XCTAssertEqual(outbox.messages[0].text, "Hello by voice")
        XCTAssertEqual(store.draft, "Unsent typed draft")
        XCTAssertEqual(store.items.first(where: { $0.id == "owner:" + requestID })?.text, "Hello by voice")
        XCTAssertNil(store.sendVoiceText("   ", using: master))
        XCTAssertEqual(outbox.messages.count, 1)
    }
}
