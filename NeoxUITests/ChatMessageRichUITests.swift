import XCTest

final class ChatMessageRichUITests: XCTestCase {
    func testChatKeyboardHasNoDoneAccessoryButton() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-neo-chat-rich-fixture"]
        app.launch()
        app.buttons["Chat"].firstMatch.tap()
        let composer = app.textFields["neoChatComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists, "Chat keyboard must not have a Done accessory button")
    }

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
