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
        XCTAssertTrue(app.buttons["markcutReviewInboxClose"].exists)
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

        XCTAssertTrue(app.buttons["markcutReviewPreviewClose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["markcutReviewApprove"].exists)
        XCTAssertFalse(app.staticTexts["VIDEOS & REVISIONS"].exists)
        XCTAssertFalse(app.staticTexts["video-a-v2"].exists)
        let picker = app.buttons["markcutReviewVersionMenu"]
        XCTAssertTrue(picker.exists)
        picker.tap()
        let historical = app.buttons["markcutReviewRevision-fixture-old"]
        XCTAssertTrue(historical.waitForExistence(timeout: 5))
        historical.tap()
        XCTAssertTrue(app.staticTexts["Historical revision · review disabled"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["markcutReviewApprove"].exists)
    }
}
