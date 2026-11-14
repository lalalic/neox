import XCTest

final class MarkcutReviewInboxUITests: XCTestCase {
    @MainActor
    func testReviewInboxCanOpenWithExistingOrEmptyLocalInbox() {
        let app = XCUIApplication()
        app.launch()
        let inbox = app.buttons["neoTopTabReviews"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        XCTAssertTrue(inbox.isEnabled)
        inbox.tap()
        // A real iPhone may already have durable local Review items. The
        // UI must open regardless of whether the inbox is empty or populated.
        XCTAssertFalse(app.staticTexts["Review Inbox"].exists)
        XCTAssertFalse(app.buttons["markcutReviewRefresh"].exists)
        // Pull-to-refresh is available even when the local inbox is empty.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        list.swipeDown()
    }

    @MainActor
    func testApprovedReviewPersistsAsReadOnlyHistoryUntilDeleted() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-completed-fixture")
        app.launch()
        app.buttons["neoTopTabReviews"].tap()
        XCTAssertFalse(app.segmentedControls.firstMatch.exists,
                       "Review must be a single chronological list")
        let group = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["markcutReviewStatusIcon"].exists)
        group.tap()
        XCTAssertTrue(app.staticTexts["Approved · sent"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["markcutReviewApprove"].exists)
        app.buttons["markcutReviewPreviewClose"].tap()
        XCTAssertFalse(app.buttons["markcutReviewOptions"].exists)
        app.buttons["markcutReviewGroup"].firstMatch.swipeLeft()
        app.buttons["markcutReviewRemoveGroup"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "markcutReviewGroup").count, 0)
    }

    @MainActor
    func testNotificationRoutesToExactlyThePreviewItem() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-markcut-review-ui-multi-fixture",
            "-markcut-notification-route-fixture"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["markcutReviewPreviewClose"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Preview only · no approval requested"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["markcutReviewApprove"].exists)
    }

    @MainActor
    func testPreviewOnlyAndPendingReviewAreDistinctInMultiItemList() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-multi-fixture")
        app.launch()
        app.buttons["neoTopTabReviews"].tap()
        let rows = app.buttons.matching(identifier: "markcutReviewGroup")
        XCTAssertEqual(rows.count, 3)
        let preview = rows.containing(NSPredicate(format: "label CONTAINS[c] %@", "Standalone")).firstMatch
        XCTAssertTrue(preview.exists)
        preview.tap()
        XCTAssertTrue(app.staticTexts["Preview only · no approval requested"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["markcutReviewApprove"].exists)
        XCTAssertFalse(app.buttons["markcutReviewRequestChanges"].exists)
    }

    @MainActor
    func testReviewListHasNoEllipsisOptionsAndKeepsSwipeDelete() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-fixture")
        app.launch()
        app.buttons["neoTopTabReviews"].tap()
        XCTAssertFalse(app.buttons["markcutReviewRefresh"].exists)
        XCTAssertFalse(app.buttons["markcutReviewOptions"].exists)
        let row = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let remove = app.buttons["markcutReviewRemoveGroup"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "markcutReviewGroup").count, 1,
                       "Deleting one review must preserve the other revision")
        XCTAssertFalse(app.staticTexts["No previews yet"].exists)
    }

    @MainActor
    func testLocalReviewGroupCanBeRemovedWithSwipe() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-fixture")
        app.launch()
        app.buttons["neoTopTabReviews"].tap()
        let group = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.swipeLeft()
        let remove = app.buttons["markcutReviewRemoveGroup"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "markcutReviewGroup").count, 1,
                       "Deleting one review must preserve the other revision")
        XCTAssertFalse(app.staticTexts["No previews yet"].exists)
    }

    @MainActor
    func testPreviewAppearsWhenMediaArrivesAfterSheetIsPresented() {
        let app = XCUIApplication()
        app.launchArguments += ["-markcut-review-ui-fixture", "-markcut-review-async-preview-fixture"]
        app.launch()
        app.buttons["neoTopTabReviews"].tap()
        let group = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        XCTAssertTrue(app.buttons["markcutReviewPreviewClose"].waitForExistence(timeout: 5))
        // The host sheet can be created before the remote media has arrived.
        // The binding-backed child must update without closing/reopening it.
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Async preview ready"].waitForExistence(timeout: 8))
        let expand = app.buttons["markcutReviewExpandVideo"]
        XCTAssertTrue(expand.isEnabled)
        expand.tap()
        let collapse = app.buttons["markcutReviewCollapseVideo"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        collapse.tap()
        XCTAssertTrue(app.buttons["markcutReviewPreviewClose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["markcutReviewApprove"].exists)
    }

    @MainActor
    func testLandscapeVideoCanExpandWithoutChangingReviewDecision() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-fixture")
        app.launch()
        app.buttons["neoTopTabReviews"].tap()
        let group = app.buttons["markcutReviewGroup"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let expand = app.buttons["markcutReviewExpandVideo"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        // The fixture has no compiled video; do not open an empty theater.
        XCTAssertFalse(expand.isEnabled)
        XCTAssertTrue(app.buttons["markcutReviewApprove"].exists)
    }

    @MainActor
    func testFeedbackStartsAtThreeLinesAndAcceptsLineBreaks() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-fixture")
        app.launch()
        app.buttons["neoTopTabReviews"].tap()
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
    func testRevisionsAppearAsSeparateChronologicalRowsWithReadOnlyHistoricalStatus() {
        let app = XCUIApplication()
        app.launchArguments.append("-markcut-review-ui-fixture")
        app.launch()

        app.buttons["neoTopTabReviews"].tap()
        let reviews = app.buttons.matching(identifier: "markcutReviewGroup")
        XCTAssertEqual(reviews.count, 2)
        XCTAssertFalse(app.segmentedControls.firstMatch.exists)
        XCTAssertTrue(reviews.element(boundBy: 0).label.contains("review-fixture-job"))
        XCTAssertTrue(reviews.element(boundBy: 1).label.contains("review-fixture-job"))
        XCTAssertTrue(app.images.matching(identifier: "markcutReviewStatusIcon").count >= 2,
                      "The left status icon distinguishes each review revision")
        reviews.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["Historical revision · review disabled"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["markcutReviewApprove"].exists)
    }
}
