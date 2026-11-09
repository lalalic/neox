import XCTest
@testable import NeoxApp

@MainActor
final class ChatComposerDictationTests: XCTestCase {
    func testStoppingWithoutMicrophoneTapIsSafe() {
        let dictation = ChatComposerDictation()
        XCTAssertFalse(dictation.isRecording)
        XCTAssertFalse(dictation.isStarting)
        dictation.stop()
        XCTAssertFalse(dictation.isRecording)
        XCTAssertEqual(dictation.transcript, "")
    }
}
