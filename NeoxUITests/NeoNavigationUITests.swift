import XCTest

final class NeoNavigationUITests: XCTestCase {
    @MainActor
    func testFourRootTabsAndConnectorActionSections() {
        let app = XCUIApplication()
        app.launchArguments.append("-neo-jobs-ui-fixture")
        app.launch()

        let tabs = app.tabBars
        for title in ["Chat", "Jobs", "Review Inbox", "Connector"] {
            XCTAssertTrue(tabs.buttons[title].waitForExistence(timeout: 15), "Missing \(title) tab")
        }

        tabs.buttons["Jobs"].tap()
        XCTAssertTrue(app.staticTexts["Running vlog edit"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Finished validation"].exists)
        // SwiftUI List rows are exposed as cells on iOS 26, not otherElements.
        XCTAssertTrue(app.staticTexts["Running"].exists)
        XCTAssertTrue(app.staticTexts["Completed"].exists)

        let runningRow = app.staticTexts["Running vlog edit"]
        XCTAssertTrue(runningRow.waitForExistence(timeout: 3))
        runningRow.swipeLeft()
        XCTAssertFalse(app.buttons["Cancel"].exists,
                       "The current gateway summary has no cancellation capability")
        runningRow.tap()
        XCTAssertTrue(app.staticTexts["Activity not available yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(
            format: "label CONTAINS %@", "currently provides Job summaries only"
        )).firstMatch.exists)

        tabs.buttons["Review Inbox"].tap()
        XCTAssertTrue(app.staticTexts["Review Inbox"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["markcutReviewInboxClose"].exists)
        XCTAssertFalse(app.staticTexts["No previews yet"].exists)

        tabs.buttons["Connector"].tap()
        XCTAssertTrue(app.buttons["connectorCreateVlog"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectorClearTemp"].exists)
        XCTAssertFalse(app.buttons["markcutReviewInboxOpen"].exists)
        app.buttons["connectorCreateVlog"].tap()
        XCTAssertTrue(app.staticTexts["Create Vlog"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testNotificationOpensReviewInboxTabNotConnectorSheet() {
        let app = XCUIApplication()
        app.launchArguments += ["-markcut-review-ui-multi-fixture",
                                 "-markcut-notification-route-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Review Inbox"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["markcutReviewPreviewClose"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["markcutReviewInboxClose"].exists)
    }
}
