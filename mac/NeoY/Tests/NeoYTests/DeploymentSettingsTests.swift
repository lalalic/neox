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
}
