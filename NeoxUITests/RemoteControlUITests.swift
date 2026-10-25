import XCTest

final class RemoteControlUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRemoteMacEntryAndSecureConnectionForm() throws {
        let app = XCUIApplication()
        app.launch()
        let entry = app.buttons["Remote Mac"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        XCTAssertTrue(app.navigationBars["Neo Remote"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["https://your-domain/mcp"].exists)
        XCTAssertTrue(app.secureTextFields["Neo token"].exists)
        XCTAssertTrue(app.buttons["Connect"].exists)
        XCTAssertTrue(app.staticTexts[
            "Connect through the existing Neo HTTPS tunnel. The token is stored in the iPhone Keychain."
        ].exists)
    }
}
