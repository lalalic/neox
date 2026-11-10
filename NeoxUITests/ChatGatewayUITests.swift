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
        XCTAssertTrue(app.buttons["neoChatAdd"].exists)
        XCTAssertTrue(app.buttons["neoChatMicrophone"].exists)
        XCTAssertTrue(app.buttons["neoChatSend"].exists)
        XCTAssertFalse(app.buttons["neoChatSend"].isEnabled)
        let composer = app.textFields["neoChatComposer"].exists ?
            app.textFields["neoChatComposer"] : app.textViews["neoChatComposer"]
        composer.tap()
        composer.typeText("Offline message")
        XCTAssertTrue(app.buttons["neoChatSend"].isEnabled)
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        let dismiss = app.buttons["Done"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        dismiss.tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        app.swipeDown()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        app.buttons["neoChatSend"].tap()
        XCTAssertTrue(app.staticTexts["Offline message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        let jobsTab = app.tabBars.buttons["Jobs"]
        jobsTab.tap()
        XCTAssertTrue(jobsTab.isSelected)
        let chatTab = app.tabBars.buttons["Chat"]
        chatTab.tap()
        XCTAssertTrue(chatTab.isSelected)
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["No messages yet"].exists)
        XCTAssertFalse(app.staticTexts["Orchestrator thread not connected"].exists)
        XCTAssertFalse(app.otherElements["neoChatError"].exists)
        XCTAssertFalse(app.otherElements["neoChatUnbound"].exists)
        // The keyboard can cover the tab bar while composing. The assertion
        // above already verifies the Chat tab and its interactive outbox;
        // tab switching is covered separately by the app's navigation tests.
    }
}

extension ChatGatewayUITests {
    func testComposerPlusOpensRealImportOptions() {
        let app = XCUIApplication()
        app.launch()
        let add = app.buttons["neoChatAdd"]
        XCTAssertTrue(add.waitForExistence(timeout: 12))
        add.tap()
        XCTAssertTrue(app.buttons["File"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Photo"].exists)
    }
}

extension ChatGatewayUITests {
    func testComposerMicrophoneIsAccessibleWithoutText() {
        let app = XCUIApplication()
        app.launch()
        let mic = app.buttons["neoChatMicrophone"]
        XCTAssertTrue(mic.waitForExistence(timeout: 12))
        XCTAssertEqual(mic.label, "Dictate")
        XCTAssertTrue(mic.isEnabled)
    }
}
