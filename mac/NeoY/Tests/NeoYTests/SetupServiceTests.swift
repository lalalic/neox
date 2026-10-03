import XCTest

@testable import NeoY

final class SetupServiceTests: XCTestCase {
    func testParserAcceptsAliasAndStatus() throws {
        XCTAssertEqual(try NeoYSetupParser.parse("neoy.setup status"), .status)
        XCTAssertEqual(try NeoYSetupParser.parse("setup"), .help(topic: nil))
        XCTAssertEqual(try NeoYSetupParser.parse(" setup  "), .help(topic: nil))
        XCTAssertEqual(try NeoYSetupParser.parse("help"), .help(topic: nil))
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
        XCTAssertThrowsError(try NeoYSetupParser.parse("help bogus")) { error in
            XCTAssertTrue(error.localizedDescription.contains("unknown topic 'bogus'"))
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

    func testParserAcceptsFederationAndEventCommands() throws {
        XCTAssertEqual(
            try NeoYSetupParser.parse("mcp add events stdio:///opt/homebrew/bin/node?arg=%2Ftmp%2Fevents.mjs"),
            .mcpAdd(name: "events", url: "stdio:///opt/homebrew/bin/node?arg=%2Ftmp%2Fevents.mjs")
        )
        XCTAssertEqual(
            try NeoYSetupParser.parse("events notify blocked \"Need approval\" human action required"),
            .eventNotify(kind: .blocked, title: "Need approval", body: "human action required")
        )
        XCTAssertEqual(try NeoYSetupParser.parse("permissions status"), .permissionsStatus)
    }

    func testParserAcceptsFeatureLifecycleCommands() throws {
        XCTAssertEqual(try NeoYSetupParser.parse("feature list"), .featureList)
        XCTAssertEqual(try NeoYSetupParser.parse("features status family-tutor"), .featureStatus("family-tutor"))
        XCTAssertEqual(try NeoYSetupParser.parse("feature install family-tutor"), .featureInstall("family-tutor"))
        XCTAssertEqual(try NeoYSetupParser.parse("feature disable family-tutor"), .featureEnable("family-tutor", enabled: false))
        XCTAssertEqual(try NeoYSetupParser.parse("feature configure family-tutor '{\"children\":[{\"id\":\"sammy\",\"name\":\"Sammy\"}]}'"), .featureConfigure(id: "family-tutor", patchJSON: "{\"children\":[{\"id\":\"sammy\",\"name\":\"Sammy\"}]}"))
        XCTAssertEqual(try NeoYSetupParser.parse("feature doctor family-tutor"), .featureAction(id: "family-tutor", action: "doctor"))
        XCTAssertEqual(try NeoYSetupParser.parse("feature setup family-tutor"), .featureSetup("family-tutor"))
        XCTAssertEqual(try NeoYSetupParser.parse("feature complete family-tutor"), .featureComplete("family-tutor"))
        XCTAssertEqual(try NeoYSetupParser.parse("help features"), .help(topic: .features))
    }

    func testV1ControlPlaneMigratesToV3WithoutLosingDiagnostics() throws {
        let directory = Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {"schemaVersion":1,"configuration":{"diagnostics":{"isEnabled":true,"level":"warning","retentionDays":21}}}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("control-plane.json"))

        let outcome = try NeoYFileControlPlaneStore(directory: directory).loadOrCreate()

        XCTAssertEqual(outcome.document.schemaVersion, 3)
        XCTAssertTrue(outcome.document.configuration.diagnostics.isEnabled)
        XCTAssertEqual(outcome.document.configuration.diagnostics.level, .warning)
        XCTAssertEqual(outcome.document.configuration.diagnostics.retentionDays, 21)
        XCTAssertEqual(outcome.document.configuration.mcpServers, [])
    }

    func testConfigurationPersistsFederationAndEventPolicy() async throws {
        let store = NeoYFileControlPlaneStore(directory: Self.makeDirectory())
        let control = NeoYControlPlaneService(store: store)

        _ = try await control.upsertMCP(.init(name: "local", url: "http://127.0.0.1:9999/mcp"))
        _ = try await control.setEvent(.completed, enabled: false)

        let persisted = try store.loadOrCreate().document.configuration
        XCTAssertEqual(persisted.mcpServers.first?.name, "local")
        XCTAssertFalse(persisted.events.completed)
    }



    func testV2ControlPlaneMigratesToV3WithCapabilitiesEnabledByDefault() throws {
        let directory = Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {"schemaVersion":2,"configuration":{"diagnostics":{"isEnabled":true,"level":"info","retentionDays":14},"startupServices":[{"name":"old","executable":"/bin/echo","arguments":["legacy"],"environment":{},"isEnabled":true,"restartPolicy":"never"}],"mcpServers":[],"events":{"blocked":true,"failure":true,"completed":true}}}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("control-plane.json"))

        let outcome = try NeoYFileControlPlaneStore(directory: directory).loadOrCreate()

        XCTAssertEqual(outcome.document.schemaVersion, 3)
        XCTAssertTrue(NeoYOptionalCapability.allCases.allSatisfy {
            outcome.document.configuration.capabilities.isEnabled($0)
        })
    }

    func testCapabilityParserAndPersistence() async throws {
        XCTAssertEqual(
            try NeoYSetupParser.parse("capability disable demo-recording"),
            .capabilitySet(.demoRecording, enabled: false)
        )
        XCTAssertEqual(try NeoYSetupParser.parse("help capabilities"), .help(topic: .capabilities))

        let store = NeoYFileControlPlaneStore(directory: Self.makeDirectory())
        let setup = NeoYSetupService(
            makeStatus: { Self.makeStatus() },
            controlPlane: NeoYControlPlaneService(store: store)
        )
        _ = await setup.execute(.capabilitySet(.demoRecording, enabled: false))
        XCTAssertFalse(try store.loadOrCreate().document.configuration.capabilities.isEnabled(.demoRecording))
    }

    func testCanonicalCoreToolSetIsSmallAndStable() {
        XCTAssertTrue(NeoYCoreRuntime.toolNames.isSuperset(of: [
            "setup", "apply_patch", "cluster", "shell_exec", "fs_read",
            "pty_start", "codex_thread_list"
        ]))
        XCTAssertFalse(NeoYCoreRuntime.toolNames.contains("exec"))
        XCTAssertFalse(NeoYCoreRuntime.toolNames.contains("fs"))
        XCTAssertFalse(NeoYCoreRuntime.toolNames.contains("codex.threads"))
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

    func testClusterIsCanonicalNodeToolName() {
        let service = NeoYNodeService()
        let names = NeoYNodeTools.tools(service: service).map(\.name)
        XCTAssertEqual(names, ["cluster"])
        XCTAssertFalse(names.contains("node"))
    }

    func testSSHAddressDefaultsPortTo22() throws {
        XCTAssertEqual(
            try NeoYSSHAddress.parse("chengli@home98"),
            NeoYSSHAddress(user: "chengli", host: "home98", port: 22)
        )
        XCTAssertEqual(
            try NeoYSSHAddress.parse("chengli@127.0.0.1#port=22022"),
            NeoYSSHAddress(user: "chengli", host: "127.0.0.1", port: 22022)
        )
    }

    func testReverseSSHProcessParsing() {
        let line = "/usr/bin/ssh -N -o BatchMode=yes -p 2222 -i /Users/lir/.ssh/id_ed25519 -R 127.0.0.1:22022:127.0.0.1:22 chengli@neo.example"
        XCTAssertEqual(
            NeoYSSHBootstrap.parseReverseSSH(from: line),
            .init(target: "chengli@neo.example", port: 2222, identityFile: "/Users/lir/.ssh/id_ed25519")
        )
    }

    func testRemoteFeatureClassification() {
        XCTAssertTrue(NeoYRemoteFeature.mcpServices.matches(toolName: "events.watch"))
        XCTAssertTrue(NeoYRemoteFeature.terminal.matches(toolName: "shell_exec"))
        XCTAssertTrue(NeoYRemoteFeature.files.matches(toolName: "fs_read"))
        XCTAssertTrue(NeoYRemoteFeature.codex.matches(toolName: "codex_thread_list"))
        XCTAssertTrue(NeoYRemoteFeature.computer.matches(toolName: "computer.click"))
        XCTAssertTrue(NeoYRemoteFeature.nodes.matches(toolName: "cluster"))
        XCTAssertFalse(NeoYRemoteFeature.nodes.matches(toolName: "node"))
        XCTAssertFalse(NeoYRemoteFeature.computer.matches(toolName: "mcp.mac.exec"))
    }

    func testV3LegacyStartupServicesAreNormalizedAway() throws {
        let directory = Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {"schemaVersion":3,"configuration":{"diagnostics":{"isEnabled":false,"level":"info","retentionDays":7},"startupServices":[{"name":"old","executable":"/bin/echo"}],"mcpServers":[],"events":{"blocked":true,"failure":true,"completed":true},"capabilities":{"disabled":[]}}}
        """
        let url = directory.appendingPathComponent("control-plane.json")
        try Data(legacy.utf8).write(to: url)

        _ = try NeoYFileControlPlaneStore(directory: directory).loadOrCreate()

        let normalized = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(normalized.contains("startupServices"))
    }

    func testV3BundledMacBridgeIsNormalizedOutOfUserFederation() throws {
        let directory = Self.makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        {"schemaVersion":3,"configuration":{"diagnostics":{"isEnabled":false,"level":"info","retentionDays":7},"mcpServers":[{"name":"macbridge","url":"stdio:///tmp/bridge.mjs","isEnabled":true},{"name":"events","url":"http://127.0.0.1:9999/mcp","isEnabled":true}],"events":{"blocked":true,"failure":true,"completed":true},"capabilities":{"disabled":[]}}}
        """
        let url = directory.appendingPathComponent("control-plane.json")
        try Data(legacy.utf8).write(to: url)

        let outcome = try NeoYFileControlPlaneStore(directory: directory).loadOrCreate()

        XCTAssertEqual(outcome.document.configuration.mcpServers.map(\.name), ["events"])
        let normalized = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(normalized.contains("\"name\" : \"macbridge\""))
    }

    func testBundledMacBridgeToolsAreFlatAndLegacyBrowserToolsAreHidden() {
        XCTAssertEqual(NeoYBundledRuntime.exposedToolName(provider: "macbridge", tool: "pty_start"), "pty_start")
        XCTAssertNil(NeoYBundledRuntime.exposedToolName(provider: "macbridge", tool: "apply_patch"))
        XCTAssertNil(NeoYBundledRuntime.exposedToolName(provider: "macbridge", tool: "chrome_click"))
        XCTAssertNil(NeoYBundledRuntime.exposedToolName(provider: "macbridge", tool: "chatgpt_conversation_start"))
        XCTAssertEqual(NeoYBundledRuntime.exposedToolName(provider: "events", tool: "health"), "events.health")
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
            mcp: NeoYRuntimeEndpoint(name: "MCP", url: "http://127.0.0.1:6767/mcp", isRunning: true, error: nil),
            neoXPairing: .unavailable,
            handoff: NeoYRuntimeEndpoint(name: "Handoff", url: "http://127.0.0.1:6767/agent", isRunning: true, error: nil),
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
