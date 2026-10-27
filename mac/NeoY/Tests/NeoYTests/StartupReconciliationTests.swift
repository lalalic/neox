import XCTest
@testable import NeoY

final class StartupReconciliationTests: XCTestCase {
    private func record(_ id: String, enabled: Bool, state: NeoYFeatureState) -> NeoYFeatureRecord {
        NeoYFeatureRecord(id: id, package: "@lalalic/\(id)", version: "1.0.0",
                          enabled: enabled, state: state, provider: id,
                          mcpURL: "http://127.0.0.1:9999/mcp", error: nil)
    }

    func testOnlyPreviouslyEnabledAndConfiguredFeaturesResume() {
        let records = [
            record("disabled", enabled: false, state: .ready),
            record("needs-setup", enabled: true, state: .setupRequired),
            record("configuring", enabled: true, state: .configuring),
            record("ready", enabled: true, state: .ready),
            record("failed", enabled: true, state: .failed),
            record("installing", enabled: true, state: .installing),
        ]
        XCTAssertEqual(NeoYFeatureManager.startupCandidates(records), ["failed", "ready"])
    }

    func testEmptyInstallationNeverInstallsAnOptionalFeature() {
        XCTAssertTrue(NeoYFeatureManager.startupCandidates([]).isEmpty)
    }

    func testRetiredCatalogEntriesCannotRestart() {
        let old = record("family-tutor", enabled: true, state: .ready)
        XCTAssertTrue(NeoYFeatureManager.startupCandidates([old], catalogIDs: []).isEmpty)
    }

    func testDisabledFeatureStillOwnsItsProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("features.json")
        let records = [
            record("family-tutor", enabled: false, state: .disabled),
            record("enabled-feature", enabled: true, state: .ready),
        ]
        try JSONEncoder().encode(records).write(to: stateURL)
        let manager = NeoYFeatureManager(root: directory, stateURL: stateURL)
        let owned = await manager.ownedProviderNames()
        let enabled = await manager.enabledMCPServers()
        XCTAssertEqual(owned, Set(["family-tutor", "enabled-feature"]))
        XCTAssertTrue(enabled.isEmpty)
    }
}
