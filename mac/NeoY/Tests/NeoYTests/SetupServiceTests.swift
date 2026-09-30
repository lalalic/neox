import XCTest

@testable import NeoY

final class SetupServiceTests: XCTestCase {
    func testParserAcceptsAliasAndStatus() throws {
        XCTAssertEqual(try NeoYSetupParser.parse("neoy.setup status"), .status)
        XCTAssertEqual(try NeoYSetupParser.parse("neoy.setup"), .help(topic: nil))
        XCTAssertEqual(try NeoYSetupParser.parse(" setup  "), .help(topic: nil))
    }

    func testParserDefaultsToOverviewHelpAndResolvesTopics() throws {
        XCTAssertEqual(try NeoYSetupParser.parse(nil), .help(topic: nil))
        XCTAssertEqual(try NeoYSetupParser.parse("help overview"), .help(topic: .overview))
        XCTAssertEqual(try NeoYSetupParser.parse("neoy.setup help \"roadmap\""), .help(topic: .roadmap))
    }

    func testParserRejectsUnknownCommandAndTopic() {
        XCTAssertThrowsError(try NeoYSetupParser.parse("startup add")) { error in
            XCTAssertEqual(error.localizedDescription, "unknown command 'startup'; run 'help'")
        }
        XCTAssertThrowsError(try NeoYSetupParser.parse("help federation")) { error in
            XCTAssertEqual(error.localizedDescription, "unknown topic 'federation'; supported topics: overview, status, roadmap")
        }
    }

    func testSetupServiceReturnsTypedStatus() async throws {
        let status = NeoYRuntimeStatus(
            state: .ready,
            version: "test",
            bundleIdentifier: "com.neox.neoy.tests",
            startupMode: "test",
            mcp: NeoYRuntimeEndpoint(name: "MCP", url: "http://127.0.0.1:9224/mcp", isRunning: true, error: nil),
            neoXPairing: .unavailable,
            handoff: NeoYRuntimeEndpoint(name: "Handoff", url: "http://127.0.0.1:8686/agent", isRunning: true, error: nil),
            capabilities: ["test"]
        )
        let service = NeoYSetupService(makeStatus: { status })

        let result = await service.execute(.status)
        let data = try XCTUnwrap(result.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "ready")
        XCTAssertEqual(object["bundle_identifier"] as? String, "com.neox.neoy.tests")
        XCTAssertEqual((object["mcp"] as? [String: Any])?["is_running"] as? Bool, true)
        XCTAssertEqual((object["neo_x_pairing"] as? [String: Any])?["is_selected"] as? Bool, false)
    }
}
