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
}
