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

    func testLegacyNamedJSONOffOnKeepsOwnDomain() throws {
        // pre-refactor file has no preferredTunnelMode key.
        let json = #"""
        {"mcpPort":6767,"tunnelMode":"named","tunnelName":"legacy",
         "publicHostname":"mcp.example.com","remoteTools":["status"]}
        """#
        let legacy = try JSONDecoder().decode(
            NeoYDeploymentSettings.self, from: Data(json.utf8))
        XCTAssertNil(legacy.preferredTunnelMode)
        XCTAssertEqual(legacy.tunnelMode, .named)

        let off = try legacy.settingRemoteEnabled(false)
        XCTAssertEqual(off.tunnelMode, .off)
        XCTAssertEqual(off.preferredTunnelMode, .named)
        let persisted = try JSONDecoder().decode(NeoYDeploymentSettings.self,
            from: JSONEncoder().encode(off))
        let on = try persisted.settingRemoteEnabled(true)
        XCTAssertEqual(on.tunnelMode, .named)
        XCTAssertEqual(on.preferredTunnelMode, .named)
        XCTAssertEqual(on.publicHostname, "mcp.example.com")
    }

    func testLegacyQuickAndOffJSONKeepExpectedMode() throws {
        for mode in ["quick", "off"] {
            let json = """
            {"mcpPort":6767,"tunnelMode":"\(mode)","tunnelName":"",
             "publicHostname":"","preferredTunnelMode":null}
            """
            let legacy = try JSONDecoder().decode(
                NeoYDeploymentSettings.self, from: Data(json.utf8))
            let off = try legacy.settingRemoteEnabled(false)
            XCTAssertEqual(off.tunnelMode, .off)
            XCTAssertEqual(off.preferredTunnelMode, .quick)
            let on = try off.settingRemoteEnabled(true)
            XCTAssertEqual(on.tunnelMode, .quick)
            XCTAssertEqual(on.preferredTunnelMode, .quick)
        }
    }
}
