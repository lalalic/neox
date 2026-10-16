import XCTest
@testable import NeoY

@MainActor
final class VoiceSessionTests: XCTestCase {
    final class FakeSynthesizer: VoiceSynthesizer {
        var spoken: [String] = []
        func speak(_ text: String) { spoken.append(text) }
        func stop() {}
    }

    func testReadOnlyNeoStatusIntentIsConstrained() {
        XCTAssertTrue(VoiceCommandRouting.isGatewayStatus("Neo 状态"))
        XCTAssertTrue(VoiceCommandRouting.isGatewayStatus("Neo status"))
        XCTAssertFalse(VoiceCommandRouting.isGatewayStatus("Neo status; rm -rf /"))
        XCTAssertFalse(VoiceCommandRouting.isGatewayStatus("delete a file"))
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
}
