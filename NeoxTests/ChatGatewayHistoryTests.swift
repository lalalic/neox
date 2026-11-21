import Foundation
import XCTest
@testable import NeoxApp

@MainActor
final class ChatGatewayHistoryTests: XCTestCase {
    private func item(_ id: String, _ text: String) throws -> ChatGatewayItem {
        try ChatGatewayItem(wire: ["id": id, "kind": "report", "text": text,
                                   "at": "2026-11-20T16:00:00Z", "level": "info"])
    }

    func testMissingRetiredMCPDoesNotBlockLocalHistoryRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = ChatGatewayHistory(file: folder.appendingPathComponent("history.json"))
        let outbox = ChatGatewayOutbox(file: folder.appendingPathComponent("outbox.json"))
        let suite = UserDefaults(suiteName: "neo-mvp-retired-mcp-" + UUID().uuidString)!
        let store = ChatGatewayStore(outbox: outbox, preferences: suite, history: history)
        await store.importLegacyIfAvailable {
            throw NSError(domain: "retired-chat-gateway", code: 404)
        }
        XCTAssertFalse(history.hasImportedLegacy, "Unavailable provider cannot mark import successful")
        XCTAssertEqual(store.items.count, 0)
        await store.importLegacyIfAvailable { [try self.item("report:a", "old saved answer")] }
        XCTAssertTrue(history.hasImportedLegacy)
        XCTAssertEqual(store.items.first?.text, "old saved answer")
    }

    func testLegacyMigrationContinuesToMergeReportsUntilCutover() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = ChatGatewayHistory(file: file)
        try history.importLegacyOnce([item("report:a", "first")])
        try history.importLegacyOnce([item("report:a", "updated"), item("report:b", "second")])
        let restored = ChatGatewayHistory(file: file)
        XCTAssertTrue(restored.hasImportedLegacy)
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertEqual(restored.items.first(where: { $0.id == "report:a" })?.text, "updated",
                       "An existing legacy report is updated by its stable ID")
        XCTAssertNotNil(restored.items.first(where: { $0.id == "report:b" }))
    }

    func testSingleProcessingPlaceholderIsReplacedAtomicallyAndNeverRegresses() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let history=ChatGatewayHistory(file:folder.appendingPathComponent("history.json"))
        try history.update(requestID:"test_request_1234",status:"processing",message:nil)
        try history.update(requestID:"test_request_1234",status:"processing",message:nil)
        XCTAssertEqual(history.items.count,1)
        XCTAssertEqual(history.items[0].text,"Processing…")
        try history.update(requestID:"test_request_1234",status:"uncertain",message:nil)
        XCTAssertEqual(history.items.count,1)
        XCTAssertEqual(history.items[0].text,"Waiting for confirmation…")
        try history.update(requestID:"test_request_1234",status:"completed",
                           message:["text":"Completed whole reply","level":"info"])
        try history.update(requestID:"test_request_1234",status:"processing",message:nil)
        XCTAssertEqual(history.items.count,1)
        XCTAssertEqual(history.items[0].text,"Completed whole reply")
        XCTAssertEqual(history.items[0].status,"completed")
        let restored=ChatGatewayHistory(file:folder.appendingPathComponent("history.json"))
        XCTAssertEqual(restored.items[0].text,"Completed whole reply")
        try restored.update(requestID:"control_only_1234",status:"processing",message:nil)
        try restored.update(requestID:"control_only_1234",status:"uncertain",message:nil)
        try restored.update(requestID:"control_only_1234",status:"completed",message:nil)
        XCTAssertEqual(restored.items.count,1,"Control-only handoff must leave no false Assistant bubble")
    }

    func testRequestOwnerAndTerminalReportSurviveRestartAndReplay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("history.json")
        let outboxFile = folder.appendingPathComponent("outbox.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let outbox = ChatGatewayOutbox(file: outboxFile)
        let request = try outbox.enqueue("persist this")
        let history = ChatGatewayHistory(file: file)
        try history.owner(request)
        XCTAssertEqual(history.items.first(where: {$0.id == "owner:" + request.id})?.status, "pending")
        try history.markSubmitted(request.id)
        XCTAssertEqual(history.items.first(where: {$0.id == "owner:" + request.id})?.status, "submitted")
        let message: [String: Any] = ["text":"done", "level":"info"]
        try history.update(requestID: request.id, status: "completed", message: message)
        try history.update(requestID: request.id, status: "completed", message: message)
        let restored = ChatGatewayHistory(file: file)
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertEqual(restored.items.first(where: { $0.id == "owner:" + request.id })?.text, "persist this")
        XCTAssertEqual(restored.items.first(where: { $0.id == "report:" + request.id })?.text, "done")
    }
}
