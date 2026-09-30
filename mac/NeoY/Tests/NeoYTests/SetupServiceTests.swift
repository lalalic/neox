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
            XCTAssertEqual(
                error.localizedDescription,
                "unknown topic 'federation'; supported topics: overview, status, roadmap, configuration, diagnostics"
            )
        }
    }

    func testParserAcceptsTypedControlPlaneCommands() throws {
        XCTAssertEqual(try NeoYSetupParser.parse("config show"), .configuration)
        XCTAssertEqual(try NeoYSetupParser.parse("diagnostics enable"), .diagnosticsEnable)
        XCTAssertEqual(try NeoYSetupParser.parse("diagnostics disable"), .diagnosticsDisable)
        XCTAssertEqual(
            try NeoYSetupParser.parse("diagnostics set level warning"),
            .diagnosticsSet(.level(.warning))
        )
        XCTAssertEqual(
            try NeoYSetupParser.parse("diagnostics set retention-days 14"),
            .diagnosticsSet(.retentionDays(14))
        )
    }

    func testParserValidatesDiagnosticsSettings() {
        XCTAssertThrowsError(try NeoYSetupParser.parse("diagnostics set retention-days 0")) { error in
            XCTAssertEqual(error.localizedDescription, "retention-days must be an integer from 1 through 365; got 0")
        }
        XCTAssertThrowsError(try NeoYSetupParser.parse("diagnostics set level verbose")) { error in
            XCTAssertEqual(error.localizedDescription, "level must be one of info, warning, error; got 'verbose'")
        }
        XCTAssertThrowsError(try NeoYSetupParser.parse("diagnostics set filename test")) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "unknown diagnostics property 'filename'; supported properties: level, retention-days"
            )
        }
    }

    func testSetupServiceReturnsTypedStatusWithControlPlaneHealth() async throws {
        let service = NeoYSetupService(makeStatus: { Self.makeStatus() }, controlPlane: Self.makeControlPlane())

        let result = await service.execute(.status)
        let data = try XCTUnwrap(result.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "ready")
        XCTAssertEqual(object["bundle_identifier"] as? String, "com.neox.neoy.tests")
        XCTAssertEqual((object["mcp"] as? [String: Any])?["is_running"] as? Bool, true)
        XCTAssertEqual((object["neo_x_pairing"] as? [String: Any])?["is_selected"] as? Bool, false)
        let controlPlane = try XCTUnwrap(object["control_plane"] as? [String: Any])
        XCTAssertEqual(controlPlane["state"] as? String, "ready")
    }

    func testControlPlaneConfigurationRoundTrip() throws {
        let store = NeoYFileControlPlaneStore(directory: Self.makeDirectory())

        var loaded = try store.loadOrCreate()
        loaded.document.configuration.diagnostics.isEnabled = true
        loaded.document.configuration.diagnostics.level = .warning
        loaded.document.configuration.diagnostics.retentionDays = 30
        try store.save(loaded.document)

        let reloaded = try store.loadOrCreate()
        XCTAssertEqual(reloaded.document, loaded.document)
        XCTAssertEqual(reloaded.health.state, .ready)
    }

    func testMalformedConfigurationIsPreservedAndReplaced() throws {
        let directory = Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"configuration\":".utf8).write(to: directory.appendingPathComponent("control-plane.json"))

        let outcome = try NeoYFileControlPlaneStore(directory: directory).loadOrCreate()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        XCTAssertEqual(outcome.document, NeoYControlPlaneDocument())
        XCTAssertEqual(outcome.health.state, .degraded)
        XCTAssertEqual(outcome.health.errorCode, "malformed_configuration")
        XCTAssertEqual(files.filter { $0.hasPrefix("control-plane-invalid-") }.count, 1)
    }

    func testUnsupportedSchemaIsReportedWithoutClaimingCurrentVersion() throws {
        let directory = Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":2}".utf8).write(to: directory.appendingPathComponent("control-plane.json"))

        let outcome = try NeoYFileControlPlaneStore(directory: directory).loadOrCreate()

        XCTAssertEqual(outcome.document.schemaVersion, NeoYControlPlaneSchema.currentVersion)
        XCTAssertEqual(outcome.health.schemaVersion, 2)
        XCTAssertEqual(outcome.health.state, .degraded)
        XCTAssertEqual(outcome.health.errorCode, "malformed_configuration")
    }

    func testSetupCommandPersistsTypedConfiguration() async throws {
        let store = NeoYFileControlPlaneStore(directory: Self.makeDirectory())
        let setup = NeoYSetupService(
            makeStatus: { Self.makeStatus() },
            controlPlane: NeoYControlPlaneService(store: store)
        )

        let result = await setup.execute(.diagnosticsSet(.retentionDays(30)))
        let decoded = try Self.decodeMutationResult(result)

        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.operation, "diagnostics.set")
        XCTAssertEqual(decoded.configuration.diagnostics.retentionDays, 30)
        XCTAssertEqual(try store.loadOrCreate().document.configuration.diagnostics.retentionDays, 30)
    }

    func testSetupCommandReportsSaveFailureAndDegradedHealth() async throws {
        let setup = NeoYSetupService(
            makeStatus: { Self.makeStatus() },
            controlPlane: NeoYControlPlaneService(store: FailingNeoYControlPlaneStore())
        )

        let result = await setup.execute(.diagnosticsEnable)
        let decoded = try Self.decodeMutationResult(result)

        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.operation, "diagnostics.enable")
        XCTAssertEqual(decoded.error, "configuration state could not be saved: injected storage failure")
        XCTAssertEqual(decoded.controlPlane.state, .degraded)
        XCTAssertEqual(decoded.controlPlane.errorCode, "configuration_save_failed")
    }

    private static func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-control-plane-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private static func makeControlPlane() -> NeoYControlPlaneService {
        NeoYControlPlaneService(store: MemoryNeoYControlPlaneStore())
    }

    private static func makeStatus() -> NeoYRuntimeStatus {
        NeoYRuntimeStatus(
            state: .ready,
            version: "test",
            bundleIdentifier: "com.neox.neoy.tests",
            startupMode: "test",
            mcp: NeoYRuntimeEndpoint(name: "MCP", url: "http://127.0.0.1:9224/mcp", isRunning: true, error: nil),
            neoXPairing: .unavailable,
            handoff: NeoYRuntimeEndpoint(name: "Handoff", url: "http://127.0.0.1:8686/agent", isRunning: true, error: nil),
            capabilities: ["test"],
            controlPlane: nil
        )
    }

    private static func decodeMutationResult(_ result: String) throws -> NeoYConfigurationMutationResult {
        let data = try XCTUnwrap(result.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NeoYConfigurationMutationResult.self, from: data)
    }
}

private struct MemoryNeoYControlPlaneStore: NeoYControlPlaneStoring {
    func loadOrCreate() throws -> NeoYControlPlaneLoadOutcome {
        NeoYControlPlaneLoadOutcome()
    }

    func save(_ document: NeoYControlPlaneDocument) throws {
        try document.validate()
    }
}

private struct FailingNeoYControlPlaneStore: NeoYControlPlaneStoring {
    func loadOrCreate() throws -> NeoYControlPlaneLoadOutcome {
        NeoYControlPlaneLoadOutcome()
    }

    func save(_ document: NeoYControlPlaneDocument) throws {
        throw NeoYControlPlaneError.saveFailed("injected storage failure")
    }
}
