import XCTest

final class NeoNavigationUITests: XCTestCase {
    @MainActor
    func testFourRootTabsAndConnectorActionSections() {
        let app = XCUIApplication()
        app.launchArguments.append("-neo-jobs-ui-fixture")
        app.launch()

        for key in ["Chat", "Jobs", "Reviews", "Connector"] {
            XCTAssertTrue(app.buttons["neoTopTab" + key].waitForExistence(timeout: 15),
                          "Missing top navigation " + key)
        }
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Native bottom bar must be hidden")

        app.buttons["neoTopTabJobs"].tap()
        XCTAssertTrue(app.staticTexts["Running vlog edit"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.navigationBars.staticTexts["Jobs"].exists,
                       "The Jobs tab identity is enough; omit the duplicate page title")
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

        app.buttons["neoTopTabReviews"].tap()
        XCTAssertFalse(app.staticTexts["Review Inbox"].exists)
        XCTAssertFalse(app.buttons["markcutReviewRefresh"].exists)
        XCTAssertFalse(app.buttons["markcutReviewInboxClose"].exists)
        XCTAssertFalse(app.staticTexts["No previews yet"].exists)

        let connectorTab = app.buttons["neoTopTabConnector"]
        XCTAssertTrue(connectorTab.waitForExistence(timeout: 10))
        XCTAssertTrue((connectorTab.value as? String ?? "").contains("iPhone connector"),
                      "Connector tab must expose its connection state")
        connectorTab.tap()
        XCTAssertFalse(app.staticTexts["iPhone ready"].exists)
        XCTAssertFalse(app.staticTexts["Starting…"].exists)
        XCTAssertTrue(app.buttons["connectorCreateVlog"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectorClearTemp"].exists)
        XCTAssertFalse(app.buttons["markcutReviewInboxOpen"].exists)
        app.buttons["connectorCreateVlog"].tap()
        XCTAssertTrue(app.staticTexts["Create Vlog"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testJobsPaginateAtBottomAndPullRefreshStartsFromFirstPage() {
        let app = XCUIApplication()
        app.launchArguments.append("-neo-jobs-pagination-fixture")
        app.launch()
        app.buttons["neoTopTabJobs"].tap()
        XCTAssertTrue(app.staticTexts["Paginated Job 1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Paginated Job 41"].exists)
        for _ in 0..<18 where !app.staticTexts["Paginated Job 41"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Paginated Job 41"].waitForExistence(timeout: 5),
                      "Bottom-of-list swipes should fetch the third page")
        for _ in 0..<18 where !app.staticTexts["Paginated Job 1"].exists {
            app.swipeDown()
        }
        XCTAssertTrue(app.staticTexts["Paginated Job 1"].waitForExistence(timeout: 6))
        // Pull-to-refresh keeps the list at the top and resets the server offset.
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Paginated Job 1"].waitForExistence(timeout: 6))
    }

    @MainActor
    func testWaitingShortcutStatusIsVisibleInJobsAndDetail() {
        let app = XCUIApplication()
        app.launchArguments.append("-neo-jobs-ui-fixture")
        app.launch()

        let jobsTab = app.buttons["neoTopTabJobs"]
        XCTAssertTrue(jobsTab.waitForExistence(timeout: 15))
        jobsTab.tap()
        let waitingRow = app.staticTexts["Waiting for event"]
        XCTAssertTrue(waitingRow.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Waiting"].exists)
        waitingRow.tap()
        XCTAssertTrue(app.staticTexts["Waiting"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Status unavailable"].exists)
    }

    @MainActor
    func testNotificationOpensReviewInboxTabNotConnectorSheet() {
        let app = XCUIApplication()
        app.launchArguments += ["-markcut-review-ui-multi-fixture",
                                 "-markcut-notification-route-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["neoTopTabReviews"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["markcutReviewPreviewClose"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["markcutReviewInboxClose"].exists)
    }
}
