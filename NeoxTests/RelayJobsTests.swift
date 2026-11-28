import SwiftUI
import XCTest
import Network
@testable import NeoxApp

@MainActor
final class RelayJobsTests: XCTestCase {
    func testSSEByteDecoderPreservesCRLFAndBlankFrameBoundaries() throws {
        let source = ": connected\r\n\r\nevent: change\r\ndata: {\"refresh\":true}\r\n\r\n" +
                     "event: change\ndata: {\"refresh\":true}\n\n"
        var decoder = GatewaySSELineBuffer(maxLineBytes: 1024)
        let lines = try source.utf8.compactMap { try decoder.append($0) }
        XCTAssertEqual(lines, [": connected", "", "event: change", "data: {\"refresh\":true}", "",
                               "event: change", "data: {\"refresh\":true}", ""])
    }

    func testSSEByteDecoderRejectsUnboundedAndMalformedUTF8() throws {
        var limited = GatewaySSELineBuffer(maxLineBytes: 4)
        for byte in "1234".utf8 { XCTAssertNil(try limited.append(byte)) }
        XCTAssertThrowsError(try limited.append(UInt8(ascii: "5")))
        var invalid = GatewaySSELineBuffer(maxLineBytes: 8)
        XCTAssertNil(try invalid.append(0xFF))
        XCTAssertThrowsError(try invalid.append(0x0A))
    }
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

    func testCancelledOnlyPageStillAdvancesAndCancelledRowsStayHidden() async throws {
        let master = RemoteMCPClient()
        let cancelled = try XCTUnwrap(RelayJob(wire: ["id": "1", "repository": "vlog", "status": "CANCELLED"]))
        let visible = try XCTUnwrap(RelayJob(wire: ["id": "2", "repository": "vlog", "status": "RUNNING"]))
        let cancelledLater = try XCTUnwrap(RelayJob(wire: ["id": "2", "repository": "vlog", "status": "CANCELLED"]))
        let other = try XCTUnwrap(RelayJob(wire: ["id": "3", "repository": "vlog", "status": "COMPLETED"]))
        var offsets: [Int] = []
        let store = RelayJobsStore(pageOperation: { offset, _ in
            offsets.append(offset)
            if offset == 0 { return RelayJobsPage(jobs: [cancelled], total: 2, nextOffset: 1, hasMore: true) }
            return RelayJobsPage(jobs: [cancelledLater, other], total: 3, nextOffset: 3, hasMore: false)
        })
        await store.refresh(from: master)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertTrue(store.hasMore)
        await store.loadMore(from: master)
        XCTAssertEqual(offsets, [0, 1])
        XCTAssertEqual(store.jobs.map(\.id), ["3"], "A cancelled duplicate in a later page removes the prior visible row")
        store.applySnapshot([cancelled, visible, cancelledLater, other])
        XCTAssertEqual(store.jobs.map(\.id), ["2", "3"])
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
        XCTAssertEqual(job.displayIdentity, "lalalic/neo/902")
        XCTAssertEqual(job.statusName, "Running")
        XCTAssertEqual(job.createdAt, "2026-11-07T09:15:00Z")
        XCTAssertTrue(job.isActive)
        XCTAssertFalse(job.canCancel, "The current gateway does not publish cancellation capability")
        XCTAssertFalse(String(describing: job).contains("private request"))
        XCTAssertFalse(String(describing: job).contains("secret"))
    }

    func testJobListIdentityWithoutRepositoryUsesIDOnly() throws {
        let job = try XCTUnwrap(RelayJob(wire: ["id": "902", "status": "RUNNING"]))
        XCTAssertEqual(job.displayIdentity, "902")
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

    func testActivityRequiresCanonicalIdentityAndRejectsLegacyRows() throws {
        XCTAssertNil(RelayJobActivityEvent(wire: [
            "id": "evt_1", "type": "task.started", "timestamp": "2026-11-08T16:40:00Z",
            "taskId": "task_8", "content": "old projection"
        ]))
        XCTAssertNil(RelayJobActivityEvent(wire: [
            "event_id": "evt_2", "job_id": "763", "type": "task.progress", "timestamp": "not-a-date"
        ]))
        let event = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "event_id": "evt_3", "job_id": "763", "type": "task.started",
            "timestamp": "2026-11-08T16:40:00.368Z", "task_id": "task_8"
        ]))
        XCTAssertEqual(event.title, "Task started")
        XCTAssertEqual(event.taskLabel, "Task task_8")
    }

    func testCanonicalHistoryKeepsIdentityStableOrderDetailsAndLatestSixty() throws {
        let base = "2026-11-27T22:29:41Z"
        var rows: [[String: Any]] = [
            ["event_id": "same-time-first", "job_id": "763", "task_id": "2443",
             "type": "new.lifecycle.event", "timestamp": base, "data": ["summary": "ordinary detail"]],
            ["event_id": "same-time-first", "job_id": "763", "type": "duplicate",
             "timestamp": base],
            ["event_id": "same-time-second", "job_id": "763", "type": "task.failed",
             "timestamp": base, "message": "Failed during verification", "data": ["phase": "verify"]],
            ["event_id": "malformed", "job_id": "763", "type": "bad", "timestamp": "invalid"]
        ]
        rows += (0..<61).map { index in
            ["event_id": "window-\(index)", "job_id": "763", "type": "task.progress",
             "timestamp": "2026-11-27T22:\(String(format: "%02d", index % 60)):41Z"]
        }
        let history = try XCTUnwrap(RelayJobActivityEvent.canonicalHistory(rows, jobID: "763"))
        XCTAssertEqual(history.count, 60)
        XCTAssertEqual(history.first?.id, "window-59")
        XCTAssertEqual(history.first(where: { $0.id == "same-time-first" })?.taskLabel, "Task 2443")
        XCTAssertEqual(history.first(where: { $0.id == "same-time-first" })?.title, "new.lifecycle.event")
        XCTAssertEqual(history.first(where: { $0.id == "same-time-first" })?.content, "Event received")
        XCTAssertTrue(history.first(where: { $0.id == "same-time-second" })?.details?.contains("verify") == true)
        XCTAssertLessThan(try XCTUnwrap(history.firstIndex(where: { $0.id == "same-time-first" })),
                          try XCTUnwrap(history.firstIndex(where: { $0.id == "same-time-second" })),
                          "Equal timestamps retain history input order")
        let fallback = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "event_id": "fallback", "job_id": "763", "type": "new.event",
            "timestamp": base, "data": ["phase": "running", "evidence": "logs clean", "next": "deploy"]
        ]))
        XCTAssertEqual(fallback.content, "running · Evidence: logs clean · Next: deploy")
        let emptyMessageFallback = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "event_id": "empty-message", "job_id": "763", "type": "new.event",
            "timestamp": base, "message": "  ", "data": ["phase": "running"]
        ]))
        XCTAssertEqual(emptyMessageFallback.content, "running")
        XCTAssertNil(RelayJobActivityEvent.canonicalHistory([
            ["event_id": "foreign", "job_id": "764", "type": "task.started", "timestamp": base]
        ], jobID: "763"))
        XCTAssertEqual(RelayJobActivityEvent.canonicalHistory([], jobID: "763")?.count, 0)
    }

    func testTaskEventNameUsesReasonEvidencePhaseThenMessage() throws {
        let base: [String: Any] = ["event_id": "evt-1", "job_id": "763", "type": "task.failed",
                                   "timestamp": "2026-11-27T22:29:41Z", "message": "task.failed"]
        let cases: [([String: Any], String)] = [
            (["reason": "Reason", "evidence": "Evidence", "phase": "Phase"], "Reason"),
            (["reason": "  ", "evidence": "Evidence", "phase": "Phase"], "Evidence"),
            (["reason": NSNull(), "evidence": "\u{0007}", "phase": "Phase"], "Phase"),
            ([:], "task.failed")
        ]
        for (data, expected) in cases {
            var wire = base
            wire["data"] = data
            XCTAssertEqual(RelayJobActivityEvent(wire: wire)?.content, expected)
        }
        var descriptive = base
        descriptive["message"] = "Meaningful message"
        descriptive["data"] = ["reason": "Do not override"]
        XCTAssertEqual(RelayJobActivityEvent(wire: descriptive)?.content, "Meaningful message")
        var nonTask = base
        nonTask["type"] = "job.completed"
        nonTask["message"] = "job.completed"
        nonTask["data"] = ["reason": "Do not override"]
        XCTAssertEqual(RelayJobActivityEvent(wire: nonTask)?.content, "job.completed")
    }

    func testTimelineAbbreviatesCommitSHAToLastSixWithoutChangingDetailsOrIdentity() throws {
        let sha1 = "5ed411079c52e2f68eba93e0396448552fc2f485"
        let sha256 = String(repeating: "a", count: 58) + "123abc"
        let message = "Verified \(sha1), then \(sha256); short abcdef, UUID 3c40ca4a-c987-416e-a192-dede1178b8ca."
        let event = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "event_id": sha1, "job_id": "763", "type": "task.progress",
            "timestamp": "2026-11-27T22:29:41Z", "message": message
        ]))
        XCTAssertEqual(event.content, "Verified c2f485, then 123abc; short abcdef, UUID 3c40ca4a-c987-416e-a192-dede1178b8ca.")
        XCTAssertEqual(event.id, sha1)
        XCTAssertTrue(event.details?.contains(sha1) == true)
        XCTAssertTrue(event.details?.contains(sha256) == true)
    }

    func testCanonicalActivity404DoesNotUseLegacyProjection() async throws {
        let ready = XCTestExpectation(description: "Canonical history fixture ready")
        let listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let canonical = request.hasPrefix("GET /relay/api/events?")
                    && request.contains("job=763") && request.contains("repo=vlog") && request.contains("limit=60")
                    && request.lowercased().contains("authorization: bearer fixture-only-test-token")
                let status = canonical ? "404 Not Found" : "200 OK"
                let body = canonical ? "{}" : #"{"repository":"vlog","jobId":"763","events":[]}"#
                let packet = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 10)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let master = RemoteMCPClient(testEndpoint: "http://127.0.0.1:\(port)/mcp", testBearer: "fixture-only-test-token")
        let job = try XCTUnwrap(RelayJob(wire: ["id": "763", "repository": "vlog", "status": "RUNNING"]))
        do {
            _ = try await master.relayJobActivity(job)
            XCTFail("Canonical 404 must fail, never load legacy history")
        } catch GatewayRESTError.http(let code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testActivityRefreshReplaysWakeDuringFetchAndRetainsSnapshotOnFailure() async throws {
        let job = try XCTUnwrap(RelayJob(wire: ["id": "763", "repository": "vlog", "status": "RUNNING"]))
        let started = expectation(description: "first canonical history fetch started")
        var calls = 0
        let store = RelayJobsStore(activityOperation: { _ in
            calls += 1
            if calls == 1 {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(80))
            }
            if calls == 3 { throw NSError(domain: "activity-fixture", code: 1) }
            let event = try XCTUnwrap(RelayJobActivityEvent(wire: [
                "event_id": "event-\(calls)", "job_id": "763", "type": "task.progress",
                "timestamp": "2026-11-27T22:29:4\(calls)Z", "message": "Fetch \(calls)"
            ]))
            return [event]
        })
        let master = RemoteMCPClient()
        let firstFetch = Task { await store.refreshActivity(for: job, from: master) }
        await fulfillment(of: [started], timeout: 2)
        store.receiveLiveChange()
        await store.refreshActivity(for: job, from: master)
        await firstFetch.value
        XCTAssertEqual(calls, 2, "A wake received during an in-flight fetch triggers a follow-up")
        XCTAssertEqual(store.activity(for: job)?.first?.id, "event-2")

        await store.refreshActivity(for: job, from: master)
        XCTAssertEqual(store.activity(for: job)?.first?.id, "event-2", "A transient failure keeps the last good history")
        XCTAssertNotNil(store.activityError(for: job))
    }

    func testActivityTaskCaptionUsesScopedTitlesAndKeepsLastGoodTitlesOnFailure() async throws {
        let job = try XCTUnwrap(RelayJob(wire: ["id": "763", "repository": "vlog", "status": "RUNNING"]))
        let other = try XCTUnwrap(RelayJob(wire: ["id": "763", "repository": "neox", "status": "RUNNING"]))
        let event = try XCTUnwrap(RelayJobActivityEvent(wire: ["event_id": "evt", "job_id": "763", "type": "task.progress",
            "timestamp": "2026-11-27T22:29:41Z", "task_id": "2443"]))
        let jobEvent = try XCTUnwrap(RelayJobActivityEvent(wire: ["event_id": "job-event", "job_id": "763", "type": "job.created",
            "timestamp": "2026-11-27T22:29:41Z"]))
        var calls = 0
        let store = RelayJobsStore(activityOperation: { _ in [event, jobEvent] }, taskTitlesOperation: { requested in
            calls += 1
            if calls == 3 { throw NSError(domain: "titles-fixture", code: 1) }
            return ["2443": requested.repository == "vlog" ? "Prepare video" : "Review Mobile"]
        })
        let master = RemoteMCPClient()
        XCTAssertEqual(store.activityTaskCaption(for: event, job: job), "2443")
        XCTAssertNil(store.activityTaskCaption(for: jobEvent, job: job))
        await store.refreshActivity(for: job, from: master)
        await store.refreshActivity(for: other, from: master)
        XCTAssertEqual(store.activityTaskCaption(for: event, job: job), "2443: Prepare video")
        XCTAssertEqual(store.activityTaskCaption(for: event, job: other), "2443: Review Mobile")
        await store.refreshActivity(for: job, from: master)
        XCTAssertEqual(store.activityTaskCaption(for: event, job: job), "2443: Prepare video")
        XCTAssertNil(store.activityError(for: job))
        XCTAssertEqual(store.activity(for: job)?.count, 2)
    }

    func testActivityIconTintUsesExactScopedTaskTitleNotEventType() async throws {
        let job = try XCTUnwrap(RelayJob(wire: ["id": "765", "repository": "agents-relay", "status": "COMPLETED"]))
        let other = try XCTUnwrap(RelayJob(wire: ["id": "765", "repository": "neox", "status": "COMPLETED"]))
        func event(_ taskID: String?, type: String = "task.progress") throws -> RelayJobActivityEvent {
            var wire: [String: Any] = ["event_id": "event-" + (taskID ?? "job"), "job_id": "765", "type": type,
                                       "timestamp": "2026-11-27T22:29:41Z"]
            if let taskID { wire["task_id"] = taskID }
            return try XCTUnwrap(RelayJobActivityEvent(wire: wire))
        }
        let trouble = try event("2454", type: "task.completed")
        let review = try event("2468", type: "task.failed")
        let implementation = try event("2450", type: "task.failed")
        let jobOnly = try event(nil, type: "review.approved")
        let store = RelayJobsStore(activityOperation: { _ in [trouble, review, implementation, jobOnly] },
                                  taskTitlesOperation: { _ in ["2454": "Troubleshooter", "2468": "Final Review", "2450": "Fix troubleshooter"] })
        XCTAssertEqual(store.activityIconTint(for: trouble, job: job), .secondary)
        await store.refreshActivity(for: job, from: RemoteMCPClient())
        XCTAssertEqual(store.activityIconTint(for: trouble, job: job), .red)
        XCTAssertEqual(store.activityIconTint(for: review, job: job), .green)
        XCTAssertEqual(store.activityIconTint(for: implementation, job: job), .secondary)
        XCTAssertEqual(store.activityIconTint(for: jobOnly, job: job), .secondary)
        XCTAssertEqual(store.activityIconTint(for: trouble, job: other), .secondary)
    }

    func testActivityUsesCanonicalRedactedMessageInsteadOfLegacyContent() throws {
        let job = try XCTUnwrap(RelayJob(wire: ["id": "658", "repository": "toyalive-3d", "status": "RUNNING"]))
        let event = try XCTUnwrap(RelayJobActivityEvent(wire: [
            "event_id": "evt_658", "job_id": "658", "type": "task.progress",
            "timestamp": "2026-11-17T11:12:00Z", "task_id": "1943",
            "message": "Verified orientation with front photo.\u{0007}",
            "content": "old projection"
        ]))
        XCTAssertEqual(RelayJobsStore().activityDescription(for: event, job: job), "Verified orientation with front photo.")
        XCTAssertEqual(event.taskLabel, "Task 1943")
        XCTAssertFalse(String(describing: event).contains("old projection"))
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
                "event_id": type, "job_id": "763", "type": type, "timestamp": "2026-11-08T16:40:00Z",
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

    func testHistoryDoesNotInventEventIdentity() {
        XCTAssertNil(RelayJobActivityEvent(wire: [
            "type": "planner.completed", "job_id": "763", "timestamp": "2026-11-10T13:50:00Z"
        ]))
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
        XCTAssertTrue(store.ordered.isEmpty, "Confirmed cancelled jobs are removed from the visible list")

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
