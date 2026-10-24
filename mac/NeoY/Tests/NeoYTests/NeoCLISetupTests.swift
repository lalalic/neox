import XCTest
@testable import NeoY

final class NeoCLISetupTests: XCTestCase {
    func testPublishedNeoCLIDistributionIdentity() {
        XCTAssertEqual(NeoCLISetup.npmCLI, "@lalalic/neo@1.0.2")
    }

    func testCLIInstalledPackageIdentity() {
        XCTAssertEqual(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.2"], executableExists: true), "ready")
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.1"], executableExists: true).hasPrefix("upgrade_required:"))
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.2"], executableExists: false).hasPrefix("upgrade_required:"))
    }

    func testLegacyNeoNeverSilentlyReplaced() {
        let result = NeoCLISetup.packageDecision(installed: ["neo": "1.0.2-p0.1"], executableExists: true)
        XCTAssertTrue(result.hasPrefix("migration_required:"))
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["neo": "1.0.2-p0.1", "@lalalic/neo": "1.0.2"], executableExists: true).hasPrefix("migration_required:"))
    }

    func testUnknownNeoNeverSilentlyReplaced() {
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: [:], executableExists: true).hasPrefix("ownership_unknown:"))
        XCTAssertEqual(NeoCLISetup.packageDecision(installed: [:], executableExists: false), "install")
    }

    func testGlobalSkillsReadOnlyInventory() {
        XCTAssertEqual(NeoCLISetup.globalSkills(), ["events-bus", "daemon-service-manage", "webhelm"])
    }

    func testOptionalSkillCatalogDoesNotIncludeCoreDependencies() {
        XCTAssertEqual(Set(NeoCLISetup.optionalSkillSources.keys),
                       Set(["wechat-bro", "markcut", "agents-relay"]))
        XCTAssertTrue(Set(NeoCLISetup.optionalSkillSources.keys)
            .isDisjoint(with: NeoCLISetup.requiredGlobalSkills))
    }

    func testOptionalMCPToolsAreBackedByRealCapabilityState() throws {
        XCTAssertEqual(Set(NeoYRemoteToolCatalog.nativeOptionalTools.keys),
                       Set(["computer", "demo", "tour", "phone"]))
        let capability = try XCTUnwrap(NeoYRemoteToolCatalog.nativeOptionalTools["computer"])
        var config = NeoYCapabilityConfiguration()
        XCTAssertTrue(config.isEnabled(capability))
        config.set(capability, enabled: false)
        XCTAssertFalse(config.isEnabled(capability))
        config.set(capability, enabled: true)
        XCTAssertTrue(config.isEnabled(capability))
    }

    func testCoreSkillsCannotBeRemovedAsOptional() {
        XCTAssertThrowsError(try NeoCLISetup.removeOptionalSkill("webhelm"))
    }
}
