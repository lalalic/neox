import XCTest

final class ChatGatewayUITests: XCTestCase {
    func testChatTabIsAvailableAndComposerIsSafeWithoutHead() {
        let app = XCUIApplication()
        app.launch()
        // Chat remains the default top-level tab even before setup.
        XCTAssertTrue(app.buttons["neoTopTabChat"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["Chat"].exists)
        XCTAssertFalse(app.buttons["neoChatRefresh"].exists)
        XCTAssertTrue(app.textFields["neoChatComposer"].exists ||
                      app.textViews["neoChatComposer"].exists)
        XCTAssertTrue(app.buttons["neoChatAdd"].exists)
        XCTAssertTrue(app.buttons["neoChatClearHistory"].exists)
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
        let jobsTab = app.buttons["neoTopTabJobs"]
        jobsTab.tap()
        XCTAssertTrue(jobsTab.isSelected)
        let chatTab = app.buttons["neoTopTabChat"]
        chatTab.tap()
        XCTAssertTrue(chatTab.isSelected)
        XCTAssertTrue(app.keyboards.element.waitForNonExistence(timeout: 3))
        composer.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["No messages yet"].exists)
        XCTAssertFalse(app.staticTexts["Orchestrator thread not connected"].exists)
        XCTAssertFalse(app.otherElements["neoChatError"].exists)
        XCTAssertFalse(app.otherElements["neoChatUnbound"].exists)
        // Top navigation remains outside the bottom keyboard/composer region.
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

extension ChatGatewayUITests {
    func testClearHistoryRequiresConfirmationAndPreservesComposer() {
        let app = XCUIApplication()
        app.launch()
        let clear = app.buttons["neoChatClearHistory"]
        XCTAssertTrue(clear.waitForExistence(timeout: 12))
        clear.tap()
        XCTAssertTrue(app.buttons["Clear displayed history"].waitForExistence(timeout: 4))
        app.buttons["neoChatConfirmClear"].firstMatch.tap()
        XCTAssertTrue(app.buttons["neoChatAdd"].exists)
        XCTAssertTrue(app.buttons["neoChatSend"].exists)
    }
}
