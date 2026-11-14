import XCTest

final class ChatMessageRichUITests: XCTestCase {
    func testChatBubbleRendersRichMessageWithoutSpeakerAndWithSmartTime() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-neo-chat-rich-fixture"]
        app.launch()
        app.buttons["Chat"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Markcut video preview"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Chat Gateway"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Orchestrator"].exists)
        XCTAssertFalse(app.staticTexts["You"].exists)
        app.buttons["Markcut video preview"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Markcut preview"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
    }
}
