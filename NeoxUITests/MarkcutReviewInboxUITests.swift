import XCTest

final class MarkcutReviewInboxUITests: XCTestCase {
    @MainActor
    func testReviewInboxOpensFromNeoStatusScreen() {
        let app = XCUIApplication()
        app.launch()

        let inbox = app.buttons["markcutReviewInboxOpen"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.tap()

        XCTAssertTrue(app.navigationBars["Review Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Markcut previews from Neo Master will appear here."].waitForExistence(timeout: 5))
    }
}
