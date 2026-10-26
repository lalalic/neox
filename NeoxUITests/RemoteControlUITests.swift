import XCTest

final class RemoteControlUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSavedMasterCanOpenWithoutBonjourDiscovery() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-neox.preferredBridge", "Offline Test Master"]
        app.launch()
        // The saved Master must remain actionable even with no nearby Macs.
        let entry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Offline Test Master")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue(entry.isEnabled)
        entry.tap()

        XCTAssertTrue(app.staticTexts["Offline Test Master"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Neo Master"].exists)
    }
}
