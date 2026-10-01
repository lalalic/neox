import XCTest
@testable import NeoY

final class FeatureBootstrapTests: XCTestCase {
    func testFeatureBootstrapToolSurfaceIsGeneric() {
        XCTAssertEqual(NeoYFeatureBootstrapTools.tools().map(\.name), ["feature.bootstrap"])
    }

    func testEventsAreCanonicalCoreTools() {
        let tools = NeoYEventsTools.tools()
        XCTAssertEqual(
            Set(tools.map(\.name)),
            Set(["events.health", "events.status", "events.history", "events.wait", "events.publish"])
        )
    }

    func testEventsRemoteFeatureMatchesEventsTools() {
        XCTAssertTrue(NeoYRemoteFeature.events.matches(toolName: "events.publish"))
        XCTAssertTrue(NeoYRemoteFeature.events.matches(toolName: "events.wait"))
        XCTAssertFalse(NeoYRemoteFeature.events.matches(toolName: "tutor.workspace"))
    }

    func testSetupRemoteFeatureIncludesFeatureBootstrap() {
        XCTAssertTrue(NeoYRemoteFeature.setup.matches(toolName: "feature.bootstrap"))
    }

    func testBootstrapStatusAndResetPersistGenerically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-feature-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = NeoYFeatureBootstrapService(
            stateURL: root.appendingPathComponent("feature-bootstrap.json"),
            events: NeoYEventsBusClient(apiURL: URL(string: "http://127.0.0.1:1")!)
        )

        let initial = await service.status(feature: nil)
        let initialData = try XCTUnwrap(initial.data(using: .utf8))
        let initialObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: initialData) as? [String: Any])
        XCTAssertEqual((initialObject["features"] as? [Any])?.count, 0)

        let reset = try await service.reset(feature: "tutor")
        let resetData = try XCTUnwrap(reset.data(using: .utf8))
        let resetObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: resetData) as? [String: Any])
        XCTAssertEqual(resetObject["feature"] as? String, "tutor")
    }
}
