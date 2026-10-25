import XCTest
@testable import NeoY

private actor VoiceCommandGate {
    private var opened = false
    private var started = false
    private var finished = false
    private var waitContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in waitContinuation = continuation }
        finished = true
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in startContinuation = continuation }
    }

    func open() {
        opened = true
        waitContinuation?.resume()
        waitContinuation = nil
    }

    func didFinish() -> Bool { finished }
}

@MainActor
final class VoiceSessionTests: XCTestCase {
    final class FakeSynthesizer: VoiceSynthesizer {
        var spoken: [String] = []
        var pending: ((Bool) -> Void)?
        var deferPlayback = false
        var didSpeak: (() -> Void)?
        func speak(_ text: String, completion: @escaping (Bool) -> Void) {
            spoken.append(text)
            didSpeak?()
            if deferPlayback { pending = completion } else { completion(true) }
        }
        func stop() { pending?(false); pending = nil }
    }

    func testReadOnlyNeoStatusIntentIsConstrained() {
        XCTAssertTrue(VoiceCommandRouting.isGatewayStatus("Neo 状态"))
        XCTAssertTrue(VoiceCommandRouting.isGatewayStatus("Neo status"))
        XCTAssertFalse(VoiceCommandRouting.isGatewayStatus("Neo status; rm -rf /"))
        XCTAssertFalse(VoiceCommandRouting.isGatewayStatus("delete a file"))
    }

    func testThreadBindingParsesProjectAndStandaloneURLsAndIDs() {
        let id = "6adb5143-bdf0-83e9-9c16-966c11d5f618"
        let project = "g-p-6ac92adf1a988191b37ed5526c72caac-orchestrators"
        let bound = VoiceThreadBinding.parse("https://chatgpt.com/g/\(project)/c/\(id)")
        XCTAssertEqual(bound?.threadID, id)
        XCTAssertEqual(bound?.projectID, project)
        XCTAssertNil(VoiceThreadBinding.parse("https://chatgpt.com/c/\(id)")?.projectID)
        XCTAssertEqual(VoiceThreadBinding.parse(id)?.threadID, id)
        XCTAssertNil(VoiceThreadBinding.parse("https://evil.example/c/\(id)"))
        XCTAssertNil(VoiceThreadBinding.parse("https://chatgpt.com/c/not-a-thread"))
        XCTAssertNil(VoiceThreadBinding.parse(" "))
    }

    func testThreadBindingPersistsWithoutProcessEnvironment() throws {
        let suite = "NeoYVoiceBindingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "6adb5143-bdf0-83e9-9c16-966c11d5f618"
        XCTAssertTrue(VoiceThreadBinding.save(id, defaults: defaults))
        XCTAssertEqual(VoiceThreadBinding.load(defaults: defaults)?.threadID, id)
        XCTAssertNotNil(defaults.data(forKey: VoiceThreadBinding.storageKey))
        let project = "g-p-6ac92adf1a988191b37ed5526c72caac-orchestrators"
        XCTAssertTrue(VoiceThreadBinding.save("https://chatgpt.com/g/\(project)/c/\(id)", defaults: defaults))
        XCTAssertEqual(VoiceThreadBinding.load(defaults: defaults)?.projectID, project)
        XCTAssertEqual(VoiceThreadBinding.load(defaults: defaults)?.displayValue, "https://chatgpt.com/g/\(project)/c/\(id)")
        XCTAssertFalse(VoiceThreadBinding.save("invalid", defaults: defaults))
        XCTAssertEqual(VoiceThreadBinding.load(defaults: defaults)?.threadID, id)
    }

    func testActiveChromeTabParsesTitleAndRejectsUnrelatedPages() {
        let id = "6adb5143-bdf0-83e9-9c16-966c11d5f618"
        let project = "g-p-6ac92adf1a988191b37ed5526c72caac-orchestrators"
        let tab = VoiceChatGPTTab.parse("https://chatgpt.com/g/\(project)/c/\(id)\nNeo App Issues and Changes\n")
        XCTAssertEqual(tab?.binding.threadID, id)
        XCTAssertEqual(tab?.binding.projectID, project)
        XCTAssertEqual(tab?.title, "Neo App Issues and Changes")
        XCTAssertNil(VoiceChatGPTTab.parse("https://example.com/c/\(id)\nOther"))
        XCTAssertNil(VoiceChatGPTTab.parse("https://chatgpt.com/\nChatGPT"))
    }

    func testMuteLifecycleIsExplicitAndReversible() {
        let controller = VoiceSessionController()
        controller.beginTestingSession(id: "lifecycle")
        XCTAssertEqual(controller.state, .listening)
        controller.setMuted(true)
        XCTAssertEqual(controller.state, .muted)
        XCTAssertTrue(controller.muted)
        controller.setMuted(false)
        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(controller.muted)
    }

    func testTextInjectionUsesCommandCompletionAndTTS() async {
        let synthesizer = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synthesizer) { session, correlation, text in
            XCTAssertEqual(session, "text-session")
            XCTAssertFalse(correlation.isEmpty)
            return .completed("完成：\(text)")
        }
        controller.beginTestingSession(id: "text-session")
        let receipt = await controller.inject(text: "打开客厅电视")
        XCTAssertEqual(receipt.status, "completed")
        XCTAssertEqual(receipt.result, "完成：打开客厅电视")
        XCTAssertEqual(synthesizer.spoken, ["完成：打开客厅电视"])
    }

    func testSubmittedCommandNeverSpeaksOrClaimsCompletion() async {
        let synthesizer = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synthesizer) { _, _, _ in .submitted }
        controller.beginTestingSession()
        let receipt = await controller.inject(text: "turn on tv")
        XCTAssertEqual(receipt.status, "submitted")
        XCTAssertNil(receipt.result)
        XCTAssertTrue(synthesizer.spoken.isEmpty)
    }

    func testAsynchronousRealReplySpeaksOnceAndRejectsStaleCallbacks() async throws {
        let synth = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synth) { _, _, _ in .submitted }
        controller.beginTestingSession(id: "voice-1")
        let pending = await controller.inject(text: "今天天气怎么样")
        XCTAssertEqual(pending.status, "submitted")
        XCTAssertTrue(synth.spoken.isEmpty)
        do { _ = try await controller.completeSubmittedReply(sessionID: "wrong", correlationID: pending.correlationID, answer: "wrong"); XCTFail("wrong session accepted") } catch {}
        let finished = try await controller.completeSubmittedReply(sessionID: pending.sessionID, correlationID: pending.correlationID, answer: "实际回复")
        XCTAssertEqual(finished.status, "completed")
        XCTAssertEqual(controller.lastReceipt?.result, "实际回复")
        XCTAssertEqual(synth.spoken, ["实际回复"])
        do { _ = try await controller.completeSubmittedReply(sessionID: pending.sessionID, correlationID: pending.correlationID, answer: "repeat"); XCTFail("duplicate accepted") } catch {}
        controller.beginTestingSession(id: "voice-2")
        do { _ = try await controller.completeSubmittedReply(sessionID: pending.sessionID, correlationID: pending.correlationID, answer: "stale"); XCTFail("stale session accepted") } catch {}
        XCTAssertEqual(synth.spoken, ["实际回复"])
    }

    func testReplySegmentsEnforceOrderAndDeduplicate() async throws {
        let synth = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synth) { _, _, _ in .submitted }
        controller.beginTestingSession(id: "segments")
        let pending = await controller.inject(text: "say hello")

        do {
            _ = try await controller.reply(sessionID: pending.sessionID, correlationID: pending.correlationID,
                                           sequence: 1, text: "world", final: true)
            XCTFail("out-of-order segment accepted")
        } catch {}

        let first = try await controller.reply(sessionID: pending.sessionID, correlationID: pending.correlationID,
                                               sequence: 0, text: "Hello ", final: false)
        XCTAssertEqual(first.status, "delivered")
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(first.final, false)
        let duplicate = try await controller.reply(sessionID: pending.sessionID, correlationID: pending.correlationID,
                                                   sequence: 0, text: "Hello ", final: false)
        XCTAssertEqual(duplicate, first)
        do {
            _ = try await controller.reply(sessionID: pending.sessionID, correlationID: pending.correlationID,
                                           sequence: 0, text: "changed", final: false)
            XCTFail("conflicting duplicate accepted")
        } catch {}

        let final = try await controller.reply(sessionID: pending.sessionID, correlationID: pending.correlationID,
                                               sequence: 1, text: "world.", final: true)
        XCTAssertEqual(final.status, "completed")
        XCTAssertEqual(final.result, "Hello world.")
        XCTAssertEqual(final.sequence, 1)
        XCTAssertEqual(final.final, true)
        XCTAssertEqual(controller.lastReceipt, final)
        XCTAssertEqual(synth.spoken, ["Hello ", "world."])
        let duplicateFinal = try await controller.reply(sessionID: pending.sessionID, correlationID: pending.correlationID,
                                                        sequence: 1, text: "world.", final: true)
        XCTAssertEqual(duplicateFinal, final)
    }

    func testNoMicMCPFacadeRoundTripSubmitsThenDeliversCorrelatedSegments() async throws {
        let synth = FakeSynthesizer()
        let server = MCPServer(name: "voice-e2e", port: 0)
        let controller = VoiceSessionController(synthesizer: synth) { session, correlation, text in
            XCTAssertEqual(session, "mcp-session")
            XCTAssertEqual(text, "你好，今天天气怎么样？")
            XCTAssertFalse(correlation.isEmpty)
            return .submitted
        }
        controller.beginTestingSession(id: "mcp-session")
        VoiceSessionTools.register(on: server, controller: controller)

        XCTAssertEqual(server.toolNames.filter { $0.hasPrefix("voice.") }, ["voice.reply"])
        let pending = await controller.inject(text: "你好，今天天气怎么样？")
        XCTAssertEqual(pending.status, "submitted")
        let sessionID = pending.sessionID
        let correlationID = pending.correlationID
        XCTAssertTrue(synth.spoken.isEmpty)

        let first = try await server.invokeRegisteredTool("voice.reply", arguments: .object([
            "session_id": .string(sessionID), "correlation_id": .string(correlationID), "sequence": .int(0),
            "text": .string("你好，"), "final": .bool(false),
        ]))
        XCTAssertEqual(try receiptObject(first)["status"] as? String, "delivered")
        let final = try await server.invokeRegisteredTool("voice.reply", arguments: .object([
            "session_id": .string(sessionID), "correlation_id": .string(correlationID), "sequence": .int(1),
            "text": .string("今天晴转多云。"), "final": .bool(true),
        ]))
        let delivered = try receiptObject(final)
        XCTAssertEqual(delivered["status"] as? String, "completed")
        XCTAssertEqual(delivered["deliveryStatus"] as? String, "delivered")
        XCTAssertEqual(delivered["result"] as? String, "你好，今天晴转多云。")
        XCTAssertEqual(synth.spoken, ["你好，", "今天晴转多云。"])
    }

    func testReplyMustMatchAuthenticatedActiveSessionAndCorrelation() async throws {
        let controller = VoiceSessionController(synthesizer: FakeSynthesizer()) { _, _, _ in .submitted }
        controller.beginTestingSession(id: "bound-session")
        let pending = await controller.inject(text: "answer me")
        do {
            _ = try await controller.reply(sessionID: "other-session", correlationID: pending.correlationID,
                                           sequence: 0, text: "forged", final: true)
            XCTFail("foreign session accepted")
        } catch {}
        do {
            _ = try await controller.reply(sessionID: pending.sessionID, correlationID: "other-correlation",
                                           sequence: 0, text: "forged", final: true)
            XCTFail("foreign correlation accepted")
        } catch {}
    }

    func testNewTurnReplacesReplyBindingWithinSameSession() async throws {
        let controller = VoiceSessionController(synthesizer: FakeSynthesizer()) { _, _, _ in .submitted }
        controller.beginTestingSession(id: "multi-turn")
        let first = await controller.inject(text: "first")
        _ = try await controller.completeSubmittedReply(sessionID: first.sessionID, correlationID: first.correlationID, answer: "one")
        let second = await controller.inject(text: "second")
        let result = try await controller.completeSubmittedReply(sessionID: second.sessionID, correlationID: second.correlationID, answer: "two")
        XCTAssertEqual(result.correlationID, second.correlationID)
        XCTAssertEqual(result.result, "two")
    }

    func testFinalReceiptWaitsForPlaybackAndCancellationOnlyStopsAudio() async throws {
        let synth = FakeSynthesizer()
        synth.deferPlayback = true
        let controller = VoiceSessionController(synthesizer: synth) { _, _, _ in .submitted }
        controller.beginTestingSession(id: "playback")
        let pending = await controller.inject(text: "reply")
        let playbackStarted = expectation(description: "playback starts")
        synth.didSpeak = { playbackStarted.fulfill() }
        let reply = Task { try await controller.completeSubmittedReply(sessionID: pending.sessionID,
                                                                         correlationID: pending.correlationID,
                                                                         answer: "spoken answer") }
        await fulfillment(of: [playbackStarted], timeout: 1)
        XCTAssertNil(controller.lastReceipt?.result)
        XCTAssertFalse(reply.isCancelled)
        synth.pending?(true)
        let delivered = try await reply.value
        XCTAssertEqual(delivered.status, "completed")
        XCTAssertEqual(delivered.deliveryStatus, "delivered")
        XCTAssertEqual(controller.lastReceipt, delivered)

        synth.pending = nil
        synth.deferPlayback = true
        controller.beginTestingSession(id: "cancel-audio")
        let commandTask = Task { await controller.inject(text: "background tool call") }
        await Task.yield()
        controller.cancelAudio()
        let commandReceipt = await commandTask.value
        XCTAssertEqual(commandReceipt.status, "submitted")
        XCTAssertNil(commandReceipt.result)
    }

    func testAudioCancellationDoesNotCancelBackgroundToolExecution() async throws {
        let synth = FakeSynthesizer()
        synth.deferPlayback = true
        let gate = VoiceCommandGate()
        let controller = VoiceSessionController(synthesizer: synth) { _, _, _ in
            await gate.hold()
            return .submitted
        }
        controller.beginTestingSession(id: "background-work")
        let command = Task { await controller.inject(text: "long running tool") }
        await gate.waitUntilStarted()
        let correlation = try XCTUnwrap(controller.lastReceipt?.correlationID)
        let playbackStarted = expectation(description: "playback starts")
        synth.didSpeak = { playbackStarted.fulfill() }
        let audio = Task { try await controller.completeSubmittedReply(sessionID: "background-work",
                                                                         correlationID: correlation,
                                                                         answer: "tool result") }
        await fulfillment(of: [playbackStarted], timeout: 1)
        controller.cancelAudio()
        let audioReceipt = try await audio.value
        XCTAssertEqual(audioReceipt.status, "cancelled")
        await gate.open()
        let commandReceipt = await command.value
        let toolFinished = await gate.didFinish()
        XCTAssertTrue(toolFinished)
        XCTAssertEqual(commandReceipt.status, "submitted")
    }

    func testCancelledReplyReceiptMeansAudioDidNotFinish() async throws {
        let synth = FakeSynthesizer()
        synth.deferPlayback = true
        let controller = VoiceSessionController(synthesizer: synth) { _, _, _ in .submitted }
        controller.beginTestingSession(id: "cancelled-reply")
        let pending = await controller.inject(text: "reply")
        let playbackStarted = expectation(description: "playback starts")
        synth.didSpeak = { playbackStarted.fulfill() }
        let reply = Task { try await controller.completeSubmittedReply(sessionID: pending.sessionID,
                                                                         correlationID: pending.correlationID,
                                                                         answer: "interrupted") }
        await fulfillment(of: [playbackStarted], timeout: 1)
        controller.cancelAudio()
        let receipt = try await reply.value
        XCTAssertEqual(receipt.status, "cancelled")
        XCTAssertEqual(receipt.deliveryStatus, "cancelled")
        XCTAssertNil(receipt.result)
    }

    // The backend may deliver voice.complete before its submission call returns.
    func testEarlyCompletedCallbackSurvivesLateSubmissionAck() async throws {
        final class ControllerBox: @unchecked Sendable {
            weak var value: VoiceSessionController?
        }
        let box = ControllerBox()
        let synth = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synth) { session, correlation, _ in
            try await box.value?.completeSubmittedReply(sessionID: session, correlationID: correlation, answer: "早到的回复")
            return .submitted
        }
        box.value = controller
        controller.beginTestingSession(id: "early")
        let receipt = await controller.inject(text: "你好")
        XCTAssertEqual(receipt.status, "completed")
        XCTAssertEqual(receipt.result, "早到的回复")
        XCTAssertEqual(synth.spoken, ["早到的回复"])
        do { _ = try await controller.completeSubmittedReply(sessionID: "early", correlationID: receipt.correlationID, answer: "duplicate"); XCTFail("duplicate accepted") } catch {}
    }

    func testFinalRecognitionAndStopSubmitOnce() async {
        let synthesizer = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synthesizer) { _, _, text in .completed("ok: \(text)") }
        controller.beginTestingSession()
        await controller.acceptRecognition(text: "Neo 状态", isFinal: true)
        await controller.stop()
        await controller.acceptRecognition(text: "duplicate", isFinal: true)
        XCTAssertEqual(controller.lastReceipt?.text, "Neo 状态")
        XCTAssertEqual(synthesizer.spoken, ["ok: Neo 状态"])
    }

    func testStopSubmitsFinalTranscriptOnlyOnce() async {
        let synthesizer = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synthesizer) { _, _, text in .completed("ok: \(text)") }
        controller.beginTestingSession()
        await controller.stop()
        await controller.stop()
        XCTAssertEqual(controller.state, .completed)
        XCTAssertNil(controller.lastReceipt) // no fabricated result for silence
        XCTAssertTrue(synthesizer.spoken.isEmpty)
    }

    func testNewSessionClearsReceiptAndSilentStopDoesNotReuseIt() async {
        let synth = FakeSynthesizer()
        let controller = VoiceSessionController(synthesizer: synth) { _, _, text in .completed("ok: \(text)") }
        controller.beginTestingSession(id: "first")
        _ = await controller.inject(text: "first command")
        XCTAssertEqual(controller.lastReceipt?.sessionID, "first")
        controller.beginTestingSession(id: "second")
        XCTAssertNil(controller.lastReceipt)
        XCTAssertEqual(controller.transcript, "")
        await controller.stop()
        XCTAssertNil(controller.lastReceipt)
    }

    func testLatePriorSessionRecognitionCannotContaminateNewSession() async {
        let controller = VoiceSessionController(synthesizer: FakeSynthesizer()) { _, _, text in .completed(text) }
        controller.beginTestingSession(id: "first")
        let oldGeneration = controller.currentRecognitionGeneration
        await controller.acceptRecognition(text: "old words", isFinal: false, generation: oldGeneration)
        controller.beginTestingSession(id: "second")
        let currentGeneration = controller.currentRecognitionGeneration
        XCTAssertNotEqual(oldGeneration, currentGeneration)
        await controller.acceptRecognition(text: "stale final", isFinal: true, generation: oldGeneration)
        XCTAssertEqual(controller.transcript, "")
        XCTAssertNil(controller.lastReceipt)
        await controller.acceptRecognition(text: "new final", isFinal: true, generation: currentGeneration)
        XCTAssertEqual(controller.lastReceipt?.text, "new final")
        XCTAssertEqual(controller.lastReceipt?.sessionID, "second")
    }

    func testCommandFailureIsReportedWithoutInventingCompletion() async {
        let controller = VoiceSessionController(synthesizer: FakeSynthesizer()) { _, _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "command unavailable"])
        }
        controller.beginTestingSession()
        let receipt = await controller.inject(text: "test")
        XCTAssertEqual(receipt.status, "failed")
        XCTAssertNil(receipt.result)
        XCTAssertEqual(receipt.error, "command unavailable")
    }

    private func receiptObject(_ result: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    }
}
