import XCTest
@testable import NeoY

final class DeploymentSettingsTests: XCTestCase {
    func testAddressDraftHasNoEffectUntilApplied() throws {
        var live = NeoYDeploymentSettings()
        live.tunnelMode = .quick
        live.preferredTunnelMode = .quick
        let draft = NeoYTunnelMode.named
        XCTAssertEqual(live.tunnelMode, .quick)
        XCTAssertEqual(live.preferredTunnelMode, .quick)

        let applied = try live.applyingRemoteAddress(
            draft, hostname: "mcp.example.com", enabled: true)
        XCTAssertEqual(applied.tunnelMode, .named)
        XCTAssertEqual(applied.preferredTunnelMode, .named)
        XCTAssertEqual(applied.publicHostname, "mcp.example.com")
        XCTAssertEqual(live.tunnelMode, .quick)
        XCTAssertEqual(live.publicHostname, "")
    }

    func testInvalidOwnDomainFailsWithoutChangingExistingSettings() {
        var live = NeoYDeploymentSettings()
        live.tunnelMode = .quick
        XCTAssertThrowsError(try live.applyingRemoteAddress(
            .named, hostname: "", enabled: true))
        XCTAssertThrowsError(try live.applyingRemoteAddress(
            .named, hostname: "https://bad.example.com", enabled: true))
        XCTAssertEqual(live.tunnelMode, .quick)
        XCTAssertNil(live.preferredTunnelMode)
    }

    func testAppliedPreferencePersistsWhileRemoteIsDisabled() throws {
        let original = NeoYDeploymentSettings()
        let updated = try original.applyingRemoteAddress(
            .named, hostname: "mcp.example.com", enabled: false)
        XCTAssertEqual(updated.tunnelMode, .off)
        XCTAssertEqual(updated.preferredTunnelMode, .named)
        let data = try JSONEncoder().encode(updated)
        let decoded = try JSONDecoder().decode(NeoYDeploymentSettings.self, from: data)
        XCTAssertEqual(decoded.preferredTunnelMode, .named)
        XCTAssertEqual(decoded.tunnelMode, .off)
    }

    func testPendingDomainSurvivesRemoteOffOnWithoutBeingApplied() throws {
        let applied = try NeoYDeploymentSettings().applyingRemoteAddress(
            .quick, hostname: "", enabled: true)
        let pendingMode = NeoYTunnelMode.named
        let pendingHostname = "draft.example.com"

        let off = try applied.settingRemoteEnabled(false)
        let backOn = try off.settingRemoteEnabled(true)
        XCTAssertEqual(off.tunnelMode, .off)
        XCTAssertEqual(off.preferredTunnelMode, .quick)
        XCTAssertEqual(backOn.tunnelMode, .quick)
        XCTAssertEqual(backOn.preferredTunnelMode, .quick)
        XCTAssertEqual(backOn.publicHostname, "")
        XCTAssertEqual(pendingMode, .named)
        XCTAssertEqual(pendingHostname, "draft.example.com")

        let committed = try backOn.applyingRemoteAddress(
            pendingMode, hostname: pendingHostname, enabled: true)
        XCTAssertEqual(committed.tunnelMode, .named)
        XCTAssertEqual(committed.publicHostname, pendingHostname)
    }

    func testExposureEditDoesNotApplyPendingDomainOrMode() throws {
        let applied = try NeoYDeploymentSettings().applyingRemoteAddress(
            .quick, hostname: "", enabled: true)
        let pendingMode = NeoYTunnelMode.named
        let pendingHostname = "draft.example.com"

        let exposed = applied.settingRemoteExposure(
            tools: ["status", "computer"], providers: ["family-tutor"])
        XCTAssertEqual(exposed.tunnelMode, .quick)
        XCTAssertEqual(exposed.preferredTunnelMode, .quick)
        XCTAssertEqual(exposed.publicHostname, "")
        XCTAssertEqual(exposed.enabledRemoteTools, ["status", "computer"])
        XCTAssertEqual(exposed.enabledRemoteProviders, ["family-tutor"])

        let committed = try exposed.applyingRemoteAddress(
            pendingMode, hostname: pendingHostname, enabled: true)
        XCTAssertEqual(committed.tunnelMode, .named)
        XCTAssertEqual(committed.publicHostname, pendingHostname)
        XCTAssertEqual(committed.enabledRemoteTools, exposed.enabledRemoteTools)
    }
}
