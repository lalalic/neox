import XCTest
@testable import NeoxApp

@MainActor
final class RelayJobsTests: XCTestCase {
    func testJobsAreMetadataOnlyAndSanitized() throws {
        let job = try XCTUnwrap(RelayJob(wire: [
            "id": "902\n", "title": "Vlog export\u{0007}", "repository": "lalalic/neo",
            "status": "RUNNING", "updatedAt": "2026-11-08T16:40:00Z",
            "createdAt": "2026-11-07T09:15:00Z",
            "prompt": "private request", "objective": "secret"
        ]))
        XCTAssertEqual(job.id, "902")
        XCTAssertEqual(job.displayTitle, "Vlog export")
        XCTAssertEqual(job.statusName, "Running")
        XCTAssertEqual(job.createdAt, "2026-11-07T09:15:00Z")
        XCTAssertTrue(job.isActive)
        XCTAssertFalse(job.canCancel, "The current gateway does not publish cancellation capability")
        XCTAssertFalse(String(describing: job).contains("private request"))
        XCTAssertFalse(String(describing: job).contains("secret"))
    }

    func testLifecyclePresentationAndOnlyRunningAnimates() {
        let statuses: [(String, RelayJobLifecycle, String)] = [
            ("PLANNING", .planning, "clock"), ("QUEUED", .queued, "clock"),
            ("RUNNING", .running, "arrow.trianglehead.2.clockwise.rotate.90"),
            ("PAUSED", .paused, "pause.circle"), ("BLOCKED", .blocked, "hand.raised.circle"),
            ("COMPLETED", .completed, "checkmark.circle"), ("SUCCEEDED", .succeeded, "checkmark.circle"),
            ("FAILED", .failed, "exclamationmark.triangle"), ("CANCELLED", .cancelled, "xmark.circle"),
            ("NEW_PRIVATE_STATE", .unknown, "questionmark.circle")
        ]
        for (raw, expected, symbol) in statuses {
            let state = RelayJobLifecycle(status: raw)
            XCTAssertEqual(state, expected)
            XCTAssertEqual(state.symbol, symbol)
            XCTAssertEqual(state.isRunning, state == .running)
        }
    }

    func testActivityAllowsOnlyKnownLifecycleFieldsAndDropsUnsafeText() throws {
        let event = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "id": "evt_1", "type": "task.started", "timestamp": "2026-11-08T16:40:00Z",
            "taskId": "task_8", "message": "private prompt", "error": "secret path"
        ]))
        XCTAssertEqual(event.title, "Task started")
        XCTAssertEqual(event.taskLabel, "Task task_8")
        XCTAssertFalse(String(describing: event).contains("private prompt"))
        XCTAssertFalse(String(describing: event).contains("secret path"))
        XCTAssertNil(RelayJobActivityEvent(wire: [
            "id": "evt_2", "type": "task.progress", "timestamp": "not-a-date", "message": "do not show"
        ]))
        XCTAssertNotNil(RelayJobActivityEvent(wire: [
            "id": "evt_3", "type": "task.completed", "timestamp": "2026-11-08T16:40:00.368Z"
        ]))
        XCTAssertNil(RelayJobActivityEvent(wire: [
            "id": "evt_4", "type": "unknown.event", "timestamp": "2026-11-08T16:40:00Z"
        ]))
        XCTAssertEqual(RelayJobActivityEvent(wire: [
            "id": "evt_5", "type": "job.blocked", "timestamp": "2026-11-08T16:40:00Z"
        ])?.title, "Job blocked")
    }

    func testActivitySymbolsComeOnlyFromAllowlistedEventTypes() throws {
        let mappings = [
            "job.created": "plus.circle", "job.planned": "doc.text",
            "task.queued": "clock", "task.started": "play.circle",
            "task.progress": "arrow.trianglehead.2.clockwise.rotate.90",
            "task.completed": "checkmark.circle", "task.failed": "exclamationmark.triangle",
            "task.cancelled": "xmark.circle", "job.cancelled": "xmark.circle",
            "job.completed": "checkmark.circle", "job.failed": "exclamationmark.triangle",
            "job.blocked": "hand.raised.circle", "review.approved": "checkmark.seal",
            "review.changes_required": "arrow.uturn.backward.circle",
            "planner.started": "wand.and.stars", "planner.completed": "doc.text",
            "job.runtime_status.changed": "arrow.trianglehead.2.clockwise.rotate.90",
            "task.created": "plus.circle", "task.dispatch": "play.circle",
            "task.process.launched": "play.circle", "task.release": "play.circle",
            "task.succeeded": "checkmark.circle", "review.created": "eye",
            "review.requested": "eye", "review.started": "eye", "review.blocked": "hand.raised.circle"
        ]
        for (type, expectedSymbol) in mappings {
            let event = try XCTUnwrap(RelayJobActivityEvent(wire: [
                "id": type, "type": type, "timestamp": "2026-11-08T16:40:00Z",
                "symbol": "exclamationmark.triangle"
            ]))
            XCTAssertEqual(event.symbol, expectedSymbol, type)
        }
    }

    func testActivityTimeIsFixedLocalizedAndIncludesDateOnlyWhenNeeded() throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = try XCTUnwrap(RelayTimestamp.parse("2026-11-10T21:00:00Z"))
        let today = try XCTUnwrap(RelayTimestamp.activityDisplay(
            "2026-11-10T16:30:00Z", referenceDate: reference, locale: locale, timeZone: timeZone
        ))
        XCTAssertTrue(today.contains("4:30"))
        XCTAssertTrue(today.contains("PM"))
        XCTAssertFalse(today.contains("2026"))

        let sameYear = try XCTUnwrap(RelayTimestamp.activityDisplay(
            "2026-11-08T16:30:00Z", referenceDate: reference, locale: locale, timeZone: timeZone
        ))
        XCTAssertTrue(sameYear.contains("Nov"))
        XCTAssertTrue(sameYear.contains("8"))
        XCTAssertFalse(sameYear.contains("2026"))

        let priorYear = try XCTUnwrap(RelayTimestamp.activityDisplay(
            "2025-11-08T16:30:00Z", referenceDate: reference, locale: locale, timeZone: timeZone
        ))
        XCTAssertTrue(priorYear.contains("2025"))
        XCTAssertNil(RelayTimestamp.activityDisplay("not-a-date"))
    }

    func testSourceActivityWithoutEventIdsUsesStableSafeUIIdentity() throws {
        let row: [String: Any] = [
            "type": "planner.completed", "timestamp": "2026-11-10T13:50:00Z",
            "taskId": "883", "details": "/private/secret"
        ]
        let event = try XCTUnwrap(RelayJobActivityEvent(wire: row, fallbackID: "597-0"))
        XCTAssertEqual(event.id, "597-0")
        XCTAssertEqual(event.title, "Planning completed")
        XCTAssertEqual(event.taskLabel, "Task 883")
        XCTAssertFalse(String(describing: event).contains("/private/secret"))
        XCTAssertNil(RelayJobActivityEvent(wire: row, fallbackID: "bad/id"))
    }

    func testCancellationRejectsCrossRepositoryReceipt() async throws {
        let source = try XCTUnwrap(RelayJob(wire: [
            "id": "44", "repository": "owner/neo", "status": "RUNNING", "cancellable": true
        ]))
        let wrongRepo = try XCTUnwrap(RelayJob(wire: [
            "id": "44", "repository": "other/neox", "status": "CANCELLED"
        ]))
        let store = RelayJobsStore(cancelOperation: { _ in wrongRepo })
        do {
            try await store.cancel(source)
            XCTFail("Cross-repository cancellation must never be accepted")
        } catch {
            XCTAssertEqual(error as? RelayJobCancellationError, .unconfirmed)
        }
    }

    func testCancellationRequiresGatewayCapabilityAndNonterminalState() throws {
        let running = try XCTUnwrap(RelayJob(wire: ["id": "44", "status": "RUNNING", "cancellable": true]))
        let completed = try XCTUnwrap(RelayJob(wire: ["id": "45", "status": "COMPLETED", "cancellable": true]))
        let noCapability = try XCTUnwrap(RelayJob(wire: ["id": "46", "status": "RUNNING"]))
        XCTAssertTrue(running.canCancel)
        XCTAssertFalse(completed.canCancel)
        XCTAssertFalse(noCapability.canCancel, "No-PR/current-contract jobs must not offer Cancel")
        let unknown = try XCTUnwrap(RelayJob(wire: ["id": "47", "status": "NEW_PRIVATE_STATE", "cancellable": true]))
        XCTAssertFalse(unknown.canCancel)
        XCTAssertFalse(unknown.isActive, "Unknown states must not be presented as active")
        XCTAssertFalse(RelayJobsStore().canCancel(running),
                       "A capability flag without an implemented authenticated operation must not expose the action")
        XCTAssertFalse(RelayJobsStore(cancelOperation: { _ in running }).canCancel(noCapability))
    }

    func testCancellationRequiresConfirmedMatchingCancelledResponse() async throws {
        let running = try XCTUnwrap(RelayJob(wire: ["id": "44", "status": "RUNNING", "cancellable": true]))
        let cancelled = try XCTUnwrap(RelayJob(wire: ["id": "44", "status": "CANCELLED"]))
        let store = RelayJobsStore(cancelOperation: { _ in cancelled })
        try await store.cancel(running)
        XCTAssertEqual(store.ordered.map(\.status), ["CANCELLED"])

        let wrongJob = try XCTUnwrap(RelayJob(wire: ["id": "other", "status": "CANCELLED"]))
        let unconfirmed = RelayJobsStore(cancelOperation: { _ in wrongJob })
        do {
            try await unconfirmed.cancel(running)
            XCTFail("A mismatched response must not claim cancellation succeeded")
        } catch {
            XCTAssertEqual(error as? RelayJobCancellationError, .unconfirmed)
        }
    }

    func testCancellationGuardsDuplicateRequestsAndReportsFailure() async throws {
        let running = try XCTUnwrap(RelayJob(wire: ["id": "44", "status": "RUNNING", "cancellable": true]))
        let store = RelayJobsStore(cancelOperation: { _ in
            try await Task.sleep(for: .milliseconds(150))
            throw RelayJobCancellationError.unconfirmed
        })
        let request = Task { try await store.cancel(running) }
        for _ in 0..<20 where !store.isCancelling(running) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(store.isCancelling(running))
        do {
            try await store.cancel(running)
            XCTFail("Duplicate cancellation must be rejected")
        } catch {
            XCTAssertEqual(error as? RelayJobCancellationError, .unsupported)
        }
        do {
            try await request.value
            XCTFail("The failed request must report failure")
        } catch {
            XCTAssertEqual(error as? RelayJobCancellationError, .unconfirmed)
        }
        XCTAssertFalse(store.isCancelling(running))
    }

    func testCompletedJobAndMalformedInput() throws {
        let job = try XCTUnwrap(RelayJob(wire: ["id": "111", "status": "COMPLETED"]))
        XCTAssertFalse(job.isActive)
        XCTAssertEqual(job.displayTitle, "Job 111")
        XCTAssertNil(RelayJob(wire: ["title": "Missing id", "status": "RUNNING"]))
        XCTAssertNil(RelayJob(wire: ["id": "42", "status": ""]))
    }

    func testCreatedTimeUsesLocalTimeAndAddsYearAcrossYearBoundary() throws {
        let locale = Locale(identifier: "en_US")
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let reference = try XCTUnwrap(RelayTimestamp.parse("2026-01-05T12:00:00Z"))
        let priorYear = try XCTUnwrap(RelayTimestamp.creationDisplay(
            "2026-01-01T01:30:00Z", referenceDate: reference, locale: locale, timeZone: zone
        ))
        XCTAssertTrue(priorYear.contains("Dec"))
        XCTAssertTrue(priorYear.contains("31"))
        XCTAssertTrue(priorYear.contains("2025"))
        XCTAssertTrue(priorYear.contains("8:30"))

        let sameYear = try XCTUnwrap(RelayTimestamp.creationDisplay(
            "2026-01-02T01:30:00Z", referenceDate: reference, locale: locale, timeZone: zone
        ))
        XCTAssertTrue(sameYear.contains("Jan"))
        XCTAssertFalse(sameYear.contains("2026"))

        let detail = try XCTUnwrap(RelayTimestamp.creationDetail(
            "2026-01-01T01:30:00Z", locale: locale, timeZone: zone
        ))
        XCTAssertTrue(detail.contains("2025"))
        XCTAssertTrue(detail.contains("December"))
    }

    func testCreatedTimeMissingOrInvalidUsesNoFabricatedDate() throws {
        let missing = try XCTUnwrap(RelayJob(wire: ["id": "1", "status": "RUNNING"]))
        let invalid = try XCTUnwrap(RelayJob(wire: [
            "id": "2", "status": "RUNNING", "createdAt": "not-a-date",
            "updatedAt": "2026-11-08T16:40:00Z"
        ]))
        XCTAssertNil(RelayTimestamp.creationDisplay(missing.createdAt))
        XCTAssertNil(RelayTimestamp.creationDisplay(invalid.createdAt))
        XCTAssertEqual(invalid.updatedAt, "2026-11-08T16:40:00Z")
    }

    func testCreatedTimeRemainsOnEachRefreshedSnapshot() throws {
        let store = RelayJobsStore()
        let first = try XCTUnwrap(RelayJob(wire: [
            "id": "7", "status": "RUNNING", "createdAt": "2026-11-07T09:15:00Z"
        ]))
        let refreshed = try XCTUnwrap(RelayJob(wire: [
            "id": "7", "status": "RUNNING", "updatedAt": "2026-11-08T16:40:00Z",
            "createdAt": "2026-11-07T09:15:00Z"
        ]))
        store.applySnapshot([first])
        store.applySnapshot([refreshed])
        XCTAssertEqual(store.ordered.first?.createdAt, "2026-11-07T09:15:00Z")
    }

}
