import XCTest
@testable import NeoY

final class NeoCLISetupTests: XCTestCase {
    func testPublishedNeoCLIDistributionIdentity() {
        XCTAssertEqual(NeoCLISetup.npmCLI, "@lalalic/neo@1.0.2")
    }

    func testGlobalSkillsReadOnlyInventory() {
        XCTAssertEqual(NeoCLISetup.globalSkills(), ["events-bus", "daemon-service-manage", "webhelm"])
    }
}
