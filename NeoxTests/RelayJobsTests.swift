import XCTest
import Network
@testable import NeoxApp

@MainActor
final class RelayJobsTests: XCTestCase {
    // Real iPhone URLSession -> NWListener -> Relay REST JSON. The old MCP
    // provider intentionally has no tools/list endpoint in this server.
    // This catches the dependency that previously left Jobs empty at cutover.
    func testDeviceRESTJobsLoadWithoutLegacyMCPConnection() async throws {
        let ready = XCTestExpectation(description: "Device localhost Relay fixture ready")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let authorized = request.lowercased().contains("authorization: bearer fixture-only-test-token")
                let routeOK = request.hasPrefix("GET /relay/api/mobile/jobs?")
                let offset = request.contains("offset=20") ? 20 : 0
                let indices = offset == 0 ? Array(1...20) : Array(21...22)
                let rows: [[String: Any]] = indices.map { i in
                    ["id": "job_\(i)", "repository": i == 20 ? "neo/toyalive-3d" : "vlog",
                     "status": "COMPLETED", "title": "Test Job \(i)",
                     "createdAt": "2026-11-20T09:00:00Z", "updatedAt": "2026-11-20T10:00:00Z"]
                }
                let responseObject: [String: Any] = ["jobs": rows, "total": 22,
                    "nextOffset": offset == 0 ? 20 : NSNull(), "hasMore": offset == 0]
                let responseData = (try? JSONSerialization.data(withJSONObject: responseObject)) ?? Data()
                let valid = authorized && routeOK
                let payload = valid ? responseData : Data(#"{"error":"invalid_fixture_request"}"#.utf8)
                let status = valid ? "200 OK" : "401 Unauthorized"
                let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                var packet = Data(header.utf8)
                packet.append(payload)
                connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 10)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let master = RemoteMCPClient(testEndpoint: "http://127.0.0.1:\(port)/mcp",
                                     testBearer: "fixture-only-test-token")
        XCTAssertFalse(master.connected, "Legacy MCP must be disconnected in this fixture")
        let store = RelayJobsStore()
        await store.refresh(from: master)
        XCTAssertNil(store.loadError, "Jobs must use bearer-authenticated REST independently")
        XCTAssertEqual(store.jobs.count, 20)
        XCTAssertEqual(store.total, 22)
        XCTAssertTrue(store.hasMore)
        XCTAssertTrue(store.jobs.contains(where: { $0.repository == "neo/toyalive-3d" }))
        await store.loadMore(from: master)
        XCTAssertEqual(store.jobs.count, 22)
        XCTAssertFalse(store.hasMore)
        XCTAssertFalse(master.connected, "No MCP dependency should be introduced")
    }

    /// One-shot physical iPhone -> TLS -> Neo Master -> live Relay integration.
    /// Test-only random bearer; NOT the real Neo Core credential or a deployed route.
    func testPhysicalDeviceFetchesLiveRelayJobsOverAuthenticatedHTTPS() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory,
                                                                in: .userDomainMask).first)
        let fixtureURL = documents.appendingPathComponent("neo-relay-e2e-20261120.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Only run when an isolated signed test tunnel is set up")
        }
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        let data = try Data(contentsOf: fixtureURL)
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let origin = config["origin"], let credential = config["token"],
              origin.hasPrefix("https://"), origin.hasSuffix(".trycloudflare.com"),
              credential.count >= 48 else {
            XCTFail("Invalid one-time HTTPS fixture configuration")
            return
        }
        let master = RemoteMCPClient(testEndpoint: origin + "/mcp",testBearer:credential)
        XCTAssertFalse(master.connected)
        let store = RelayJobsStore()
        await store.refresh(from: master)
        XCTAssertNil(store.loadError, "True device-to-Mac HTTPS Jobs must not require MCP")
        XCTAssertEqual(store.jobs.count, 20)
        XCTAssertGreaterThan(store.total, 400, "Real Relay has hundreds of Jobs")
        XCTAssertTrue(store.hasMore)
        for _ in 0..<30 {
            if !store.hasMore { break }
            await store.loadMore(from: master)
        }
        XCTAssertEqual(store.jobs.count, store.total,
                       "All actual Relay pages must be reachable on physical iPhone")
        XCTAssertTrue(store.jobs.contains(where: { $0.repository == "neo/toyalive-3d" }),
                      "Keep scoped repositories from the real Relay inventory")
        XCTAssertFalse(master.connected, "Never depend on the retired MCP discovery")
    }

    func testPagesLoadTwentyAtATimeAndPullRefreshResetsToFirstPage() async throws {
        let master = RemoteMCPClient()
        let rows = (1...47).compactMap { id in
            RelayJob(wire: ["id": String(id), "repository": "vlog",
                            "status": "COMPLETED", "title": "Job \(id)",
                            "createdAt": "2026-11-12T10:00:00Z",
                            "updatedAt": "2026-11-12T10:00:00Z"])
        }
        var offsets: [Int] = []
        let store = RelayJobsStore(pageOperation: { offset, limit in
            offsets.append(offset)
            let page = Array(rows.dropFirst(offset).prefix(limit))
            let next = offset + page.count
            return RelayJobsPage(jobs: page, total: rows.count,
                                 nextOffset: next, hasMore: next < rows.count)
        })
        await store.refresh(from: master)
        XCTAssertEqual(store.jobs.count, 20)
        XCTAssertEqual(store.total, 47)
        XCTAssertTrue(store.hasMore)
        await store.loadMore(from: master)
        XCTAssertEqual(store.jobs.count, 40)
        await store.loadMore(from: master)
        XCTAssertEqual(store.jobs.count, 47)
        XCTAssertFalse(store.hasMore)
        await store.loadMore(from: master)
        XCTAssertEqual(offsets, [0, 20, 40], "Never fetch beyond the final page")
        await store.refresh(from: master)
        XCTAssertEqual(store.jobs.count, 20)
        XCTAssertTrue(store.hasMore)
        XCTAssertEqual(offsets, [0, 20, 40, 0])
    }

    func testPagesDeduplicateOverlappingJobsAndPreserveRowsOnFailure() async throws {
        let master = RemoteMCPClient()
        let first = try XCTUnwrap(RelayJob(wire: ["id": "619", "repository": "vlog", "status": "RUNNING"]))
        let replacement = try XCTUnwrap(RelayJob(wire: ["id": "619", "repository": "vlog", "status": "COMPLETED"]))
        let another = try XCTUnwrap(RelayJob(wire: ["id": "625", "repository": "content-distribution", "status": "COMPLETED"]))
        var failRefresh = false
        let store = RelayJobsStore(pageOperation: { offset, _ in
            if failRefresh { throw CancellationError() }
            switch offset {
            case 0: return RelayJobsPage(jobs: [first], total: 3, nextOffset: 1, hasMore: true)
            case 1: return RelayJobsPage(jobs: [replacement, another], total: 3, nextOffset: 3, hasMore: false)
            default: throw CancellationError()
            }
        })
        await store.refresh(from: master)
        await store.loadMore(from: master)
        XCTAssertEqual(store.jobs.count, 2)
        XCTAssertEqual(store.currentJob(matching: first).status, "COMPLETED")
        XCTAssertFalse(store.hasMore)
        failRefresh = true
        await store.refresh(from: master)
        XCTAssertEqual(store.jobs.count, 2, "Failed refresh retains last successful snapshot")
        XCTAssertNotNil(store.loadError, "A failed fetch must remain visible to the owner")
        XCTAssertEqual(store.currentJob(matching: first).status, "COMPLETED")
    }

    func testFailedInitialFetchNeverPretendsRelayHasNoJobs() async throws {
        let master = RemoteMCPClient()
        var fail = true
        let job = try XCTUnwrap(RelayJob(wire: [
            "id": "678", "repository": "vlog", "status": "RUNNING"
        ]))
        let store = RelayJobsStore(pageOperation: { _, _ in
            if fail { throw CancellationError() }
            return RelayJobsPage(jobs: [job], total: 1, nextOffset: 1, hasMore: false)
        })
        await store.refresh(from: master)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.hasLoaded)
        fail = false
        await store.refresh(from: master)
        XCTAssertNil(store.loadError, "A successful retry must clear the error")
        XCTAssertEqual(store.jobs.map(\.id), ["678"])
    }

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
            ("WAITING", .waiting, "hourglass"), ("IDLE", .idle, "hourglass"),
            ("REVIEWING", .reviewing, "eye"), ("MERGE_PENDING", .mergePending, "arrow.triangle.merge"),
            ("PAUSED", .paused, "pause.circle"), ("BLOCKED", .blocked, "hand.raised.circle"),
            ("MERGED", .merged, "checkmark.circle"),
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

    func testShortcutRuntimeStatusIsNonterminalAndAllowsGatewayAuthorizedCancellation() throws {
        for status in ["WAITING", "IDLE", "REVIEWING", "MERGE_PENDING"] {
            let job = try XCTUnwrap(RelayJob(wire: [
                "id": "42", "repository": "local/vlog", "status": status, "cancellable": true
            ]))
            XCTAssertTrue(job.isActive, status)
            XCTAssertTrue(job.canCancel, status)
            XCTAssertFalse(job.lifecycle.isRunning, status)
            XCTAssertFalse(job.lifecycle.isTerminal, status)
            let legacy = try XCTUnwrap(RelayJob(wire: [
                "id": "43", "repository": "local/vlog", "status": status
            ]))
            XCTAssertFalse(legacy.canCancel, "No gateway capability: \(status)")
        }
        for status in ["MERGED", "COMPLETED", "FAILED", "CANCELLED"] {
            let job = try XCTUnwrap(RelayJob(wire: [
                "id": "42", "status": status, "cancellable": true
            ]))
            XCTAssertFalse(job.isActive, status)
            XCTAssertFalse(job.canCancel, status)
        }
    }

    func testDetailResolvesNewestJobByRepositoryAndID() throws {
        let store = RelayJobsStore()
        let original = try XCTUnwrap(RelayJob(wire: [
            "id": "605", "repository": "local/vlog", "status": "RUNNING",
            "createdAt": "2026-11-08T09:00:00Z"
        ]))
        let updated = try XCTUnwrap(RelayJob(wire: [
            "id": "605", "repository": "local/vlog", "status": "WAITING",
            "createdAt": "2026-11-08T09:00:00Z"
        ]))
        let collision = try XCTUnwrap(RelayJob(wire: [
            "id": "605", "repository": "other/neo", "status": "FAILED"
        ]))
        store.applySnapshot([original, collision])
        XCTAssertEqual(store.currentJob(matching: original).statusName, "Running")
        store.applySnapshot([updated, collision])
        XCTAssertEqual(store.currentJob(matching: original).statusName, "Waiting")
        XCTAssertEqual(store.currentJob(matching: collision).statusName, "Failed")
        XCTAssertEqual(store.currentJob(matching: original).createdAt, original.createdAt)
        store.applySnapshot([])
        XCTAssertEqual(store.currentJob(matching: original).statusName, "Running",
                       "Temporary missing row retains the navigation snapshot")
    }

    func testWaitingShortcutJobsSortAheadOfCompletedJobs() throws {
        let store = RelayJobsStore()
        let completed = try XCTUnwrap(RelayJob(wire: [
            "id": "1", "repository": "local/vlog", "status": "COMPLETED",
            "updatedAt": "2026-11-10T15:00:00Z"
        ]))
        let waiting = try XCTUnwrap(RelayJob(wire: [
            "id": "2", "repository": "local/vlog", "status": "WAITING",
            "updatedAt": "2026-11-09T15:00:00Z"
        ]))
        store.applySnapshot([completed, waiting])
        XCTAssertEqual(store.ordered.map(\.id), ["2", "1"])
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

    func testActivityUsesRedactedGatewayContentInsteadOfEventType() throws {
        let job = try XCTUnwrap(RelayJob(wire: [
            "id": "658", "repository": "toyalive-3d", "status": "RUNNING"
        ]))
        let content = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "id": "evt_658", "type": "task.progress",
            "timestamp": "2026-11-17T11:12:00Z", "taskId": "1943",
            "content": "Verified orientation with front photo.\u{0007}",
            "message": "private prompt and token", "data": ["secret": "/private/path"]
        ]))
        let store = RelayJobsStore()
        XCTAssertEqual(store.activityDescription(for: content, job: job), "Verified orientation with front photo.")
        XCTAssertEqual(content.taskLabel, "Task 1943")
        XCTAssertEqual(content.symbol, "arrow.trianglehead.2.clockwise.rotate.90")
        XCTAssertFalse(String(describing: content).contains("private prompt"))
        let old = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "id": "older", "type": "task.started", "timestamp": "2026-11-17T11:01:00Z",
            "taskId": "1943", "message": "private prompt"
        ]))
        XCTAssertEqual(store.activityDescription(for: old, job: job), "Task started",
                       "Old gateways remain safe and usable")
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
