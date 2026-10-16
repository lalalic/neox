import XCTest
@testable import NeoY

@MainActor
final class VoiceSessionTests: XCTestCase {
    final class FakeSynthesizer: VoiceSynthesizer {
        var spoken: [String] = []
        func speak(_ text: String) { spoken.append(text) }
        func stop() {}
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
            return "完成：\(text)"
        }
        controller.beginTestingSession(id: "text-session")
        let receipt = await controller.inject(text: "打开客厅电视")
        XCTAssertEqual(receipt.status, "completed")
        XCTAssertEqual(receipt.result, "完成：打开客厅电视")
        XCTAssertEqual(synthesizer.spoken, ["完成：打开客厅电视"])
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
