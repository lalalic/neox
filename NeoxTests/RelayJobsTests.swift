import XCTest
@testable import NeoxApp

@MainActor
final class RelayJobsTests: XCTestCase {
    func testJobsAreMetadataOnlyAndSanitized() throws {
        let job = try XCTUnwrap(RelayJob(wire: [
            "id": "902\n", "title": "Vlog export\u{0007}", "repository": "lalalic/neo",
            "status": "RUNNING", "updatedAt": "2026-11-08T16:40:00Z",
            "prompt": "private request", "objective": "secret"
        ]))
        XCTAssertEqual(job.id, "902")
        XCTAssertEqual(job.displayTitle, "Vlog export")
        XCTAssertEqual(job.statusName, "Running")
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
}
