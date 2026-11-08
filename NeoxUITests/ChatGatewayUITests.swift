import XCTest

final class ChatGatewayUITests: XCTestCase {
    func testChatTabIsAvailableAndComposerIsSafeWithoutHead() {
        let app = XCUIApplication()
        app.launch()
        // Chat remains the default top-level tab even before setup.
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["Chat"].exists)
        XCTAssertFalse(app.buttons["neoChatRefresh"].exists)
        XCTAssertTrue(app.textFields["neoChatComposer"].exists ||
                      app.textViews["neoChatComposer"].exists)
        XCTAssertTrue(app.buttons["neoChatSend"].exists)
        XCTAssertFalse(app.buttons["neoChatSend"].isEnabled)
        let composer = app.textFields["neoChatComposer"].exists ?
            app.textFields["neoChatComposer"] : app.textViews["neoChatComposer"]
        composer.tap()
        composer.typeText("Offline message")
        XCTAssertTrue(app.buttons["neoChatSend"].isEnabled)
        app.buttons["neoChatSend"].tap()
        XCTAssertTrue(app.staticTexts["Offline message"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No messages yet"].exists)
        XCTAssertFalse(app.staticTexts["Orchestrator thread not connected"].exists)
        XCTAssertFalse(app.otherElements["neoChatError"].exists)
        XCTAssertFalse(app.otherElements["neoChatUnbound"].exists)
        // The keyboard can cover the tab bar while composing. The assertion
        // above already verifies the Chat tab and its interactive outbox;
        // tab switching is covered separately by the app's navigation tests.
    }
}
