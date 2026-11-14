import XCTest
@testable import NeoxApp

final class MarkcutReviewDecisionTests: XCTestCase {
    @MainActor
    func testReviewRequestPersistenceReplayAndRemovalArePhoneOwned() throws {
        let suite = "MarkcutReviewInboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = try MarkcutReviewRequest(id: "00000000-0000-4000-8000-000000000001",
            contentHash: String(repeating: "a", count: 64), revisionID: "rev-2", title: "Cut review",
            groupID: "creative-1", groupTitle: "Creative", ownerCallbackTool: "vlog.review.feedback")
        let store = MarkcutReviewInboxStore(defaults: defaults)

        let firstAccepted = store.accept(request, notify: false)
        let replayAccepted = store.accept(request, notify: false)
        let restored = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertTrue(firstAccepted)
        XCTAssertFalse(replayAccepted, "replayed request UUID must be idempotent")
        XCTAssertEqual(restored, [request])

        store.remove(request.id)
        XCTAssertFalse(store.accept(request, notify: false), "late APNs must not resurrect a removed review")
        let afterRemoval = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertTrue(afterRemoval.isEmpty,
                      "local refresh/relaunch must not restore removed rows")
    }

    @MainActor
    func testRequestValidationAndToolRegistration() throws {
        XCTAssertThrowsError(try MarkcutReviewRequest(id: "not-uuid", contentHash: String(repeating: "a", count: 64),
            revisionID: "rev", title: "Cut"))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString, contentHash: String(repeating: "A", count: 64),
            revisionID: "rev", title: "Cut"))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString, contentHash: String(repeating: "a", count: 64),
            revisionID: " ", title: "Cut"))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "a", count: 64), revisionID: "rev", title: "Unsafe",
            ownerCallbackTool: "neo.shell.exec"))
        let invalidJSON = """
            {"id":"not-a-uuid","contentHash":"\(String(repeating: "a", count: 64))",
             "revisionId":"rev","title":"Invalid"}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(MarkcutReviewRequest.self,
            from: Data(invalidJSON.utf8)))
        let unsafeCallbackJSON = """
            {"id":"\(UUID().uuidString)","contentHash":"\(String(repeating: "a", count: 64))",
             "revisionId":"rev","title":"Invalid","ownerCallbackTool":"neo.shell.exec"}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(MarkcutReviewRequest.self,
            from: Data(unsafeCallbackJSON.utf8)))
        let server = MCPServer()
        XCTAssertFalse(server.toolNames.contains("review.request"),
                       "Neo Mobile review ingress belongs to Neo Master APNs, not the phone MCP")
    }

    @MainActor
    func testChatGPTOwnerRoutingAndReceiptRequirements() throws {
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "c", count: 64), revisionID: "rev-3", title: "Test",
            ownerCallbackTool: "chatgpt", ownerThreadID: "6ae92acc-cd28-83ea-8dc6-224653c9b433")
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .changesRequested,
            feedback: "Needs a transition", idempotencyKey: "test-key-1")
        let message = MarkcutReviewFeedback.chatGPTMessage(request: request, feedback: feedback)
        XCTAssertTrue(message.contains(request.id))
        XCTAssertTrue(message.contains(request.contentHash))
        XCTAssertTrue(message.contains("test-key-1"))
        XCTAssertTrue(message.contains("Needs a transition"))
        XCTAssertNoThrow(try MarkcutReviewFeedback.requireChatGPTReceipt([
            "status": "submitted", "mode": "new-turn"]))
        XCTAssertThrowsError(try MarkcutReviewFeedback.requireChatGPTReceipt([
            "status": "submitted", "mode": "new-thread"]))
        XCTAssertThrowsError(try MarkcutReviewFeedback.requireChatGPTReceipt([
            "status": "queued", "mode": "new-turn"]))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "c", count: 64), revisionID: "rev", title: "No thread",
            ownerCallbackTool: "chatgpt"))
        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(MarkcutReviewRequest.self, from: encoded), request)
    }

    @MainActor
    func testQuestionnaireMarkdownSceneAnswersSurviveMobileEventSubmit() throws {
        let template = MarkcutReviewEventTemplate(type: "task.interactive_decision",
            source: "job/1/task/2/execution/3",
            data: ["interactive": .object(["jobId": .string("1"), "taskId": .string("2"),
                "executionId": .string("3")])], responseKey: "interactive")
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "d", count: 64), revisionID: "ignored",
            title: "Vlog 问题", mode: "questions", customTitle: true, delivery: "event", eventTemplate: template)
        let roundTrip = try JSONDecoder().decode(MarkcutReviewRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(roundTrip.mode, "questions")
        XCTAssertEqual(roundTrip.customTitle, true)
        XCTAssertEqual(roundTrip.groupingValue["mode"] as? String, "questions")
        var answer1 = MarkcutReviewComment(sceneId: "scene-q1", timeSeconds: 0, text: "加拿大生活", scope: "scene")
        answer1.sceneName = "Q1"
        var answer2 = MarkcutReviewComment(sceneId: "scene-q2", timeSeconds: 0, text: "", scope: "scene")
        answer2.sceneName = "Q2"
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .approved, feedback: "",
            idempotencyKey: "stable-submit-key", comments: [answer1, answer2])
        let event = try template.event(review: feedback.reviewResult(request: roundTrip))
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        let response = try XCTUnwrap(data["interactive"] as? [String: Any])
        XCTAssertEqual(response["decision"] as? String, "approved")
        let comments = try XCTUnwrap(response["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(comments[0]["sceneName"] as? String, "Q1")
        XCTAssertEqual(comments[0]["text"] as? String, "加拿大生活")
        XCTAssertEqual(comments[1]["sceneName"] as? String, "Q2")
        XCTAssertEqual(comments[1]["text"] as? String, "")
        let normal = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "e", count: 64), revisionID: "r1", title: "Normal")
        XCTAssertTrue((feedback.reviewResult(request: normal)["comments"] as? [[String: Any]])?.isEmpty == true)
    }

    @MainActor
    func testAPNsCarriesOnlyRequestIdentityAndTextPreviewCanBeReadOnly() throws {
        let id = UUID().uuidString
        XCTAssertEqual(ReviewPushCoordinator.reviewRequestID(["neoReviewRequestId": id]), id)
        XCTAssertNil(ReviewPushCoordinator.reviewRequestID(["neoReviewRequestId": "invalid"]))
        XCTAssertNil(ReviewPushCoordinator.reviewRequestID(["neoReview": ["id": id]]))
        let preview = try MarkcutReviewRequest(id: id,
            contentHash: String(repeating: "a", count: 64), revisionID: "r1",
            title: "Read-only Text Preview", delivery: "text")
        XCTAssertFalse(preview.canDeliver)
    }

    @MainActor
    func testFeedbackRemainsQueuedWithoutOwnerAcknowledgement() throws {
        let suite = "MarkcutReviewFeedbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "b", count: 64), revisionID: "rev-1", title: "Review",
            ownerCallbackTool: "vlog.review.feedback")
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .approved,
            feedback: "", idempotencyKey: UUID().uuidString)
        let store = MarkcutReviewInboxStore(defaults: defaults)
        store.accept(request, notify: false)
        store.queue(feedback)

        XCTAssertThrowsError(try MarkcutReviewFeedback.requireAcknowledgement(["accepted": true]))
        let queuedFeedback = MarkcutReviewInboxStore(defaults: defaults).feedbackQueue
        let pendingRequests = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertEqual(queuedFeedback, [feedback])
        XCTAssertEqual(pendingRequests, [request])
        XCTAssertNoThrow(try MarkcutReviewFeedback.requireAcknowledgement(["acknowledged": true]))
        store.acknowledge(feedback)
        let afterAcknowledgement = MarkcutReviewInboxStore(defaults: defaults).requests
        XCTAssertEqual(afterAcknowledgement, [request])
        let reopened = MarkcutReviewInboxStore(defaults: defaults)
        XCTAssertEqual(reopened.completed[request.id]?.feedback, feedback)
        XCTAssertEqual(reopened.groupedSessions.first?["status"] as? String, "decided")
        XCTAssertEqual((reopened.groupedSessions.first?["decision"] as? [String: Any])?["decision"] as? String, "approved")
        XCTAssertTrue(reopened.feedbackQueue.isEmpty)
        reopened.remove(request.id)
        XCTAssertTrue(MarkcutReviewInboxStore(defaults: defaults).completed.isEmpty)
        XCTAssertTrue(MarkcutReviewInboxStore(defaults: defaults).requests.isEmpty)
    }

    @MainActor
    func testEventDeliveryTemplateValidationAndReviewResultSerialization() throws {
        let template = MarkcutReviewEventTemplate(type: "task.interactive_decision",
            source: "job/j123/task/producer/execution/e456",
            data: ["interactive": .object([
                "jobId": .string("j123"), "taskId": .string("producer"),
                "executionId": .string("e456")
            ])], responseKey: "interactive")
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "b", count: 64), revisionID: "e456",
            title: "Review scene", delivery: "event", eventTemplate: template,
            previewID: "preview-42")
        let comment = MarkcutReviewComment(sceneId: "intro", timeSeconds: 4.25,
            text: "Remove second pause", scope: "spot")
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .changesRequested,
            feedback: "Remove second pause", idempotencyKey: "stable-retry-key", comments: [comment])
        let result = feedback.reviewResult(request: request)
        let event = try template.event(review: result)
        XCTAssertEqual(event["source"] as? String, template.source)
        XCTAssertEqual(event["type"] as? String, "task.interactive_decision")
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        let interactive = try XCTUnwrap(data["interactive"] as? [String: Any])
        XCTAssertNil(interactive["revision"])
        XCTAssertNil(interactive["commitSha"])
        XCTAssertNil(interactive["revisionId"])
        XCTAssertNil(interactive["contentHash"])
        XCTAssertEqual(interactive["previewId"] as? String, "preview-42")
        XCTAssertEqual(interactive["decision"] as? String, "changes_requested")
        XCTAssertEqual(interactive["feedback"] as? String, "Remove second pause")
        XCTAssertEqual(interactive["idempotencyKey"] as? String, "stable-retry-key")
        let comments = try XCTUnwrap(interactive["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.first?["sceneId"] as? String, "intro")
        XCTAssertEqual(comments.first?["timeSeconds"] as? Double, 4.25)
        let restored = try JSONDecoder().decode(MarkcutReviewRequest.self,
            from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.eventTemplate, template)
        XCTAssertTrue(restored.canDeliver)
        // Mobile transports valid opaque event types and sources. Only the caller owns the semantics.
        XCTAssertNoThrow(try MarkcutReviewEventTemplate(
            type: "another.product.feedback", source: "custom/feedback-channel",
            data: ["extra": .string("opaque")]).validate())
        XCTAssertThrowsError(try MarkcutReviewEventTemplate(
            type: "another.product.feedback", source: "bad\nsource",
            data: [:]).validate())
        XCTAssertThrowsError(try MarkcutReviewEventTemplate(
            type: "another.product.feedback", source: "custom/channel",
            data: ["interactive": .object(["decision": .string("approved")])],
            responseKey: "interactive").validate())
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: request.contentHash, revisionID: "rev", title: "Bad",
            delivery: "event", eventTemplate: MarkcutReviewEventTemplate(
                type: "task.completed", source: "invalid\nsource", data: [:])))
        XCTAssertThrowsError(try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: request.contentHash, revisionID: "rev", title: "Bad",
            delivery: "event", eventTemplate: nil))
    }

    @MainActor
    func testGenericEventCanRoundTripAndSubmitWithoutTaskOrRelayFields() throws {
        let template = MarkcutReviewEventTemplate(type: "other.feedback.saved",
            source: "arbitrary/app-channel", data: ["context": .string("unchanged"),
            "payload": .object(["userOwned": .string("opaque")])], responseKey: "payload")
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "a", count: 64), revisionID: "transport-only",
            title: "Other product review", delivery: "event", eventTemplate: template)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(MarkcutReviewRequest.self, from: encoded)
        XCTAssertEqual(decoded.eventTemplate, template)
        let feedback = MarkcutReviewFeedback(requestId: request.id, decision: .approved,
            feedback: "", idempotencyKey: "same-on-retry")
        let event = try XCTUnwrap(decoded.eventTemplate?.event(review: feedback.reviewResult(request: decoded)))
        XCTAssertEqual(event["type"] as? String, "other.feedback.saved")
        XCTAssertEqual(event["source"] as? String, "arbitrary/app-channel")
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        let result = try XCTUnwrap(data["payload"] as? [String: Any])
        XCTAssertEqual(result["userOwned"] as? String, "opaque")
        XCTAssertEqual(result["decision"] as? String, "approved")
        XCTAssertEqual(result["idempotencyKey"] as? String, "same-on-retry")
    }

    @MainActor
    func testEventFeedbackRetryPreservesRequestAndIdempotencyAcrossRelaunch() throws {
        let suite = "MarkcutReviewEventRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "c", count: 64), revisionID: "e8", title: "Review",
            delivery: "event", eventTemplate: MarkcutReviewEventTemplate(
                type: "task.interactive_decision",
                source: "job/j8/task/review/execution/e8",
                data: ["interactive": .object([
                    "jobId": .string("j8"), "taskId": .string("review"),
                    "executionId": .string("e8")
                ])]))
        let queued = MarkcutReviewFeedback(requestId: request.id, decision: .approved,
            feedback: "", idempotencyKey: "retry-key-preserved")
        let inbox = MarkcutReviewInboxStore(defaults: defaults)
        XCTAssertTrue(inbox.accept(request, notify: false))
        inbox.queue(queued)
        let restored = MarkcutReviewInboxStore(defaults: defaults)
        XCTAssertEqual(restored.requests, [request])
        XCTAssertEqual(restored.feedbackQueue, [queued])
        XCTAssertEqual(restored.feedbackQueue[0].reviewResult(request: request)["idempotencyKey"] as? String,
                       "retry-key-preserved")
        XCTAssertEqual(restored.feedbackQueue[0].reviewResult(request: request)["comments"] as? [[String: String]], [])
        restored.acknowledge(queued)
        XCTAssertEqual(MarkcutReviewInboxStore(defaults: defaults).requests, [request])
        XCTAssertEqual(MarkcutReviewInboxStore(defaults: defaults).completed[request.id]?.feedback, queued)
    }

    @MainActor
    func testNewVideoRevisionMakesOldMobileRequestReadonly() throws {
        let suite = "MarkcutReviewStale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = MarkcutReviewInboxStore(defaults: defaults)
        let old = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "1", count: 64), revisionID: "r1",
            title: "Cut v1", groupID: "same-video", ownerCallbackTool: "review.feedback")
        let new = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "2", count: 64), revisionID: "r2",
            title: "Cut v2", groupID: "same-video", ownerCallbackTool: "review.feedback")
        XCTAssertTrue(inbox.accept(old, notify: false))
        XCTAssertTrue(inbox.isCurrent(old))
        XCTAssertTrue(inbox.accept(new, notify: false))
        XCTAssertFalse(inbox.isCurrent(old))
        XCTAssertTrue(inbox.isCurrent(new))
        // Acknowledging the latest review must not reactivate an older revision.
        inbox.acknowledge(MarkcutReviewFeedback(requestId: new.id,
            decision: .approved, feedback: "", idempotencyKey: "ack-new"))
        XCTAssertFalse(inbox.isCurrent(old))
        XCTAssertFalse(MarkcutReviewInboxStore(defaults: defaults).isCurrent(old))
        XCTAssertEqual(inbox.groupedSessions.first(where: {$0["id"] as? String == old.id})?["status"] as? String,
                       "superseded")
    }

    func testReviewGroupingKeepsJobSessionsTogetherAndSeparatesJobs() {
        let sessions: [[String: Any]] = [
            ["id":"a", "label":"video-a-v1", "status":"ready", "createdAt":"2026-11-01T10:00:00Z",
             "relayCorrelations":[["jobId":"job-one", "taskId":"task-a"]]],
            ["id":"b", "label":"video-a-v2", "status":"superseded", "createdAt":"2026-11-01T11:00:00Z",
             "relayCorrelations":[["jobId":"job-one", "taskId":"task-a"]]],
            ["id":"c", "label":"video-a-v3", "status":"ready", "createdAt":"2026-11-01T12:00:00Z",
             "relayCorrelations":[["jobId":"job-two", "taskId":"task-b"]]]
        ]

        let groups = MarkcutReviewGrouping.groups(from: sessions)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first(where: { $0.jobID == "job-one" })?.sessions.map(\.reviewSessionID), ["b", "a"])
        XCTAssertEqual(groups.first(where: { $0.jobID == "job-one" })?.pendingCount, 1)
        XCTAssertEqual(groups.first(where: { $0.jobID == "job-one" })?.title, "Job #job-one")
    }

    func testReviewRowsShowTaskIdAndActualTaskTitle() throws {
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "a", count: 64), revisionID: "rev",
            title: "626:Growth 第一条爆款复刻 · 六阶段审核",
            groupID: "job/626/task/1683", jobID: "626", delivery: "text")
        let value = request.groupingValue
        let relays = try XCTUnwrap(value["relayCorrelations"] as? [[String: Any]])
        XCTAssertEqual(relays.first?["taskId"] as? String, "1683")
        XCTAssertEqual(MarkcutReviewGrouping.rowSubtitle(value,
            taskTitles: ["626/1683": "growth-researcher"]), "1683:growth-researcher")
        XCTAssertEqual(MarkcutReviewGrouping.rowSubtitle(value), "1683:Task")
        let standalone = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "b", count: 64), revisionID: "rev",
            title: "Standalone preview", delivery: "text")
        XCTAssertEqual(MarkcutReviewGrouping.rowSubtitle(standalone.groupingValue), "Preview only")
    }

    @MainActor
    func testWrapperProvidedReviewLabelsPersistOnlyInPhoneLocalHistory() throws {
        let suite = "MarkcutWrapperLabels.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MarkcutReviewInboxStore(defaults: defaults)
        let request = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "a", count: 64), revisionID: "review",
            title: "626:Growth 第一条爆款复刻 · 六阶段审核",
            subtitle: "1683:growth-researcher", groupID: "job/626/task/1683",
            jobID: "626", delivery: "text")
        XCTAssertTrue(store.accept(request, notify: false))
        let restored = MarkcutReviewInboxStore(defaults: defaults)
        XCTAssertEqual(restored.requests.count, 1)
        XCTAssertEqual(restored.requests[0].subtitle, "1683:growth-researcher")
        XCTAssertEqual(MarkcutReviewGrouping.rowSubtitle(restored.groupedSessions[0]),
                       "1683:growth-researcher")
        XCTAssertEqual(MarkcutReviewGrouping.groups(from: restored.groupedSessions).count, 1)
    }

    func testLocalReviewHistoryGroupsExecutionsByJobAndTaskWithoutDroppingRevisions() {
        let sessions: [[String: Any]] = [
            ["id": "old-626", "status": "superseded", "createdAt": "2026-11-13T14:00:00Z",
             "relayCorrelations": [["jobId": "626", "taskId": "1683"]]],
            ["id": "new-626", "status": "ready", "createdAt": "2026-11-13T15:00:00Z",
             "relayCorrelations": [["jobId": "626", "taskId": "1683"]]],
            ["id": "old-627", "status": "superseded", "createdAt": "2026-11-13T14:10:00Z",
             "relayCorrelations": [["jobId": "627", "taskId": "1685"]]],
            ["id": "new-627", "status": "ready", "createdAt": "2026-11-13T15:10:00Z",
             "relayCorrelations": [["jobId": "627", "taskId": "1685"]]],
            ["id": "another-task", "status": "ready", "createdAt": "2026-11-13T16:10:00Z",
             "relayCorrelations": [["jobId": "627", "taskId": "1686"]]],
        ]
        let groups = MarkcutReviewGrouping.groups(from: sessions)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first(where: { $0.id == "job:626:task:1683" })?.sessions.map(\.reviewSessionID),
                       ["new-626", "old-626"])
        XCTAssertEqual(groups.first(where: { $0.id == "job:627:task:1685" })?.sessions.map(\.reviewSessionID),
                       ["new-627", "old-627"])
        XCTAssertEqual(groups.first(where: { $0.id == "job:627:task:1686" })?.sessions.count, 1)
        XCTAssertEqual(groups.reduce(0) { $0 + $1.sessions.count }, sessions.count)
    }

    func testInboxUsesPhoneLocalCalendarDateNotUTCDay() {
        let toronto = TimeZone(identifier: "America/Toronto")!
        XCTAssertEqual(MarkcutReviewGrouping.localDate("2026-11-14T01:05:31.628Z", timeZone: toronto), "2026-11-13")
        XCTAssertEqual(MarkcutReviewGrouping.localDate("2026-11-13T13:03:32.159Z", timeZone: toronto), "2026-11-13")
    }

    func testInboxRowsShowJobIDsEvenWhenOriginalTitlesAreGhostFiles() {
        let sessions: [[String: Any]] = [
            ["id":"a", "title":".ghost.growth-review-growth-researcher", "status":"ready",
             "createdAt":"2026-11-13T19:00:00Z", "relayCorrelations":[["jobId":"626"]]],
            ["id":"b", "title":".ghost.growth-review-growth-researcher", "status":"ready",
             "createdAt":"2026-11-13T19:01:00Z", "relayCorrelations":[["jobId":"626"]]],
            ["id":"c", "title":".ghost.growth-review-growth-researcher", "status":"ready",
             "createdAt":"2026-11-13T19:02:00Z", "relayCorrelations":[["jobId":"627"]]],
            ["id":"d", "title":"Questions", "customTitle":true, "status":"ready",
             "createdAt":"2026-11-13T19:03:00Z"],
            ["id":"e", "title":".ghost.markcut", "status":"ready",
             "videoGroupKey":"/tmp/.ghost.markcut.md", "createdAt":"2026-11-13T19:04:00Z"]
        ]
        let groups = MarkcutReviewGrouping.groups(from: sessions)
        let jobTitles = ["626": "Growth 第一条爆款复刻 · 六阶段审核",
                         "627": "Growth 复刻小红书收藏·千评评论动机·六阶段审核"]
        let titles = groups.flatMap { group in
            group.sessions.map { MarkcutReviewGrouping.rowTitle(group: group, revision: $0, jobTitles: jobTitles) }
        }
        XCTAssertEqual(titles.filter { $0 == "626:Growth 第一条爆款复刻 · 六阶段审核" }.count, 2)
        XCTAssertEqual(titles.filter { $0 == "627:Growth 复刻小红书收藏·千评评论动机·六阶段审核" }.count, 1)
        XCTAssertTrue(titles.contains(where: { $0.hasPrefix("Questions") }))
        XCTAssertTrue(titles.contains("Preview"))
        XCTAssertFalse(titles.contains(where: { $0.contains(".ghost") }))
        XCTAssertEqual(MarkcutReviewGrouping.rowTitle(group: groups.first(where: { $0.jobID == "626" })!,
            revision: groups.first(where: { $0.jobID == "626" })!.sessions[0]), "626")
    }

    func testSessionWithMultipleRelayCorrelationsIsVisibleInEachCorrelatedJob() {
        let session: [String: Any] = ["id":"shared-session", "label":"clip", "status":"ready",
            "relayCorrelations":[["jobId":"job-one"], ["jobId":"job-two"]]]

        let groups = MarkcutReviewGrouping.groups(from: [session])

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.sessions.map(\.reviewSessionID) == ["shared-session"] })
    }

    func testOpaqueVideoGroupKeysKeepRevisionsTogetherWithoutExposingPaths() {
        let sessions: [[String: Any]] = [
            ["id":"a", "videoGroupKey":"source-one", "videoGroupTitle":"v1", "status":"ready"],
            ["id":"b", "videoGroupKey":"source-one", "videoGroupTitle":"v1", "status":"superseded"],
            ["id":"c", "videoGroupKey":"source-two", "videoGroupTitle":"v2", "status":"ready"]
        ]
        let groups = MarkcutReviewGrouping.groups(from: sessions)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first(where: { $0.id == "video:source-one" })?.sessions.count, 2)
        XCTAssertEqual(groups.first(where: { $0.id == "video:source-one" })?.title, "V1")
        XCTAssertEqual(groups.first(where: { $0.id == "video:source-one" })?.pendingCount, 1)
    }

    func testDatedCreativeJobGetsCompactHeader() {
        let groups = MarkcutReviewGrouping.groups(from: [
            ["id":"a", "videoGroupKey":"run", "videoGroupTitle":"2026-11-02-rsboost-backup", "status":"ready"]
        ])
        XCTAssertEqual(groups.first?.title, "Rsboost Backup · 11/02")
    }

    func testStandaloneRunTitlesAndChronologicalSort() throws {
        let older = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "a", count: 64), revisionID: "old",
            title: "video", groupID: "/Users/test/neo/vlog/runs/2026-11-05-evening-walk/video.md",
            delivery: "text", createdAt: "2026-11-05T10:00:00.000Z")
        let newer = try MarkcutReviewRequest(id: UUID().uuidString,
            contentHash: String(repeating: "b", count: 64), revisionID: "new",
            title: "video", groupID: "/Users/test/neo/vlog/runs/2026-11-06-history-multigps/video.md",
            delivery: "text", createdAt: "2026-11-06T10:00:00.000Z")
        let groups = MarkcutReviewGrouping.groups(from: [older.groupingValue, newer.groupingValue])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.title), ["History Multigps · 11/06", "Evening Walk · 11/05"])
        XCTAssertEqual(groups.map { $0.sessions.first?.reviewSessionID }, [newer.id, older.id])
        XCTAssertTrue(groups.allSatisfy { $0.pendingCount == 0 })
        XCTAssertEqual(MarkcutReviewGrouping.statusText(newer.groupingValue), "Preview only")
    }

    @MainActor
    func testExistingLocalRowsGainMasterTimestampAfterSync() throws {
        let suite = "MarkcutTimestampTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID().uuidString
        let original = try MarkcutReviewRequest(id: id,
            contentHash: String(repeating: "c", count: 64), revisionID: "rev",
            title: "video", groupID: "run1", delivery: "text")
        let store = MarkcutReviewInboxStore(defaults: defaults)
        XCTAssertTrue(store.accept(original, notify: false))
        let enriched = try MarkcutReviewRequest(id: id,
            contentHash: original.contentHash, revisionID: "rev",
            title: "video", groupID: "run1", delivery: "text",
            createdAt: "2026-11-07T05:10:00.000Z")
        XCTAssertFalse(store.accept(enriched, notify: false))
        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(MarkcutReviewInboxStore(defaults: defaults).requests.first?.createdAt, enriched.createdAt)
    }

    func testFallbackGroupsByParentAndKeepsGenericBasenamesWithoutParentSeparate() {
        let sessions: [[String: Any]] = [
            ["id":"a", "path":"/work/creative-a/video.md", "status":"ready"],
            ["id":"b", "path":"/work/creative-a/video.md", "status":"superseded"],
            ["id":"c", "label":"video.md", "status":"ready"],
            ["id":"d", "label":"video.md", "status":"ready"]
        ]

        let groups = MarkcutReviewGrouping.groups(from: sessions)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.first(where: { $0.id == "parent:work/creative-a" })?.sessions.count, 2)
        XCTAssertNotEqual(groups.first(where: { $0.sessions.contains(where: { $0.reviewSessionID == "c" }) })?.id,
                          groups.first(where: { $0.sessions.contains(where: { $0.reviewSessionID == "d" }) })?.id)
    }
}
