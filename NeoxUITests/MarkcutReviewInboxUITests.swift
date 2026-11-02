import XCTest

final class MarkcutReviewInboxUITests: XCTestCase {
    @MainActor
    func testReviewInboxOpensFromNeoStatusScreen() {
        let app = XCUIApplication()
        app.launch()

        let inbox = app.buttons["markcutReviewInboxOpen"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.tap()

        XCTAssertTrue(app.staticTexts["Review Inbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["markcutReviewInboxClose"].exists)
        XCTAssertTrue(app.staticTexts["Markcut previews from Neo Master will appear here."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPreviewAppearsWhenMediaArrivesAfterSheetIsPresented() {
        let app = XCUIApplication()
        app.launchArguments += ["-markcut-review-ui-fixture", "-markcut-review-async-preview-fixture"]
        app.launch()
        app.buttons["markcutReviewInboxOpen"].tap()
        let group = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        XCTAssertTrue(app.buttons["markcutReviewPreviewClose"].waitForExistence(timeout: 5))
        // The host sheet can be created before the remote media has arrived.
        // The binding-backed child must update without closing/reopening it.
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Async preview ready"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testFeedbackStartsAtThreeLinesAndAcceptsLineBreaks() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-fixture")
        app.launch()
        app.buttons["markcutReviewInboxOpen"].tap()
        let group = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let textView = app.textViews["markcutReviewFeedback"]
        let textField = app.textFields["markcutReviewFeedback"]
        let field = textView.exists ? textView : textField
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(field.frame.height, 58)
        field.tap()
        field.typeText("Opening feedback\nMiddle feedback\nClosing feedback")
        let text = field.value as? String ?? ""
        XCTAssertTrue(text.contains("Opening feedback"))
        XCTAssertTrue(text.contains("Middle feedback"))
        XCTAssertTrue(text.contains("Closing feedback"))
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
        XCTAssertTrue(app.textViews["markcutReviewFeedback"].exists || app.textFields["markcutReviewFeedback"].exists)
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
