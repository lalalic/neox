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

    @MainActor
    func testRevisionPickerStaysWithinSelectedJobAndDisablesHistoricalDecision() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-fixture")
        app.launch()

        app.buttons["markcutReviewInboxOpen"].tap()
        let job = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(job.waitForExistence(timeout: 5))
        XCTAssertTrue(job.label.contains("Job #review-fixture-job"))
        job.tap()

        let current = app.buttons["markcutReviewRevision-fixture-current"]
        let historical = app.buttons["markcutReviewRevision-fixture-old"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(historical.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready for review"].exists)
        XCTAssertTrue(app.buttons["markcutReviewApprove"].exists)

        historical.tap()
        XCTAssertTrue(app.staticTexts["video-a-v1"].exists)
        XCTAssertTrue(app.staticTexts["Historical revision · review disabled"].exists)
        XCTAssertFalse(app.buttons["markcutReviewApprove"].exists)
    }
}
