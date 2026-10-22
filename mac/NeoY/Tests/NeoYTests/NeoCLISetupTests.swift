import XCTest
@testable import NeoY

final class NeoCLISetupTests: XCTestCase {
    func testMissingArtifactDoesNotInstallUntrustedPublicPackage() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tgz")
        // On a configured development machine, the existing CLI takes precedence.
        let result = try NeoCLISetup.installIfMissing(packageTarball: missing)
        XCTAssertTrue(result.contains("already installed") || result.contains("Developer CLI retained") || result.contains("needs setup"))
    }

    func testGlobalSkillsReadOnlyInventory() {
        XCTAssertEqual(NeoCLISetup.globalSkills(), NeoCLISetup.globalSkills().sorted())
    }
}
