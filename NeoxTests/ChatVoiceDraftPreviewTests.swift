import XCTest
@testable import NeoxApp

final class ChatVoiceDraftPreviewTests: XCTestCase {
    func testPendingSpeechAppearsInComposerAndCommitRestoresTypedDraft() {
        var preview = ChatVoiceDraftPreview()
        preview.begin(draft: "Saved typed")
        let partial = preview.render(transcript: "今", currentDraft: "Saved typed")
        XCTAssertEqual(partial, "Saved typed 今")
        let final = preview.render(transcript: "今天天气好", currentDraft: partial!)
        XCTAssertEqual(final, "Saved typed 今天天气好")
        XCTAssertEqual(preview.committed(currentDraft: final!), "Saved typed")
        XCTAssertEqual(preview.render(transcript: "再见", currentDraft: "Saved typed"), "Saved typed 再见")
    }

    func testEditingDuringVoiceNeverGetsOverwritten() {
        var preview = ChatVoiceDraftPreview()
        preview.begin(draft: "Draft")
        XCTAssertEqual(preview.render(transcript: "hello", currentDraft: "Draft"), "Draft hello")
        XCTAssertNil(preview.render(transcript: "hello world", currentDraft: "Changed by user"))
        XCTAssertEqual(preview.committed(currentDraft: "Changed by user"), "Changed by user")
        XCTAssertNil(preview.render(transcript: "later", currentDraft: "Other manual edit"))
    }

    func testStopKeepsPendingTranscriptionInInput() {
        var preview = ChatVoiceDraftPreview()
        preview.begin(draft: "")
        XCTAssertEqual(preview.render(transcript: "not yet sent", currentDraft: ""), "not yet sent")
        preview.cancel()
        XCTAssertNil(preview.render(transcript: "new text", currentDraft: "not yet sent"))
    }

    func testMaximumLengthAndEmptyTranscript() {
        var preview = ChatVoiceDraftPreview()
        preview.begin(draft: "")
        XCTAssertNil(preview.render(transcript: "   ", currentDraft: ""))
        let longText = String(repeating: "a", count: 2001)
        XCTAssertEqual(preview.render(transcript: longText, currentDraft: "")?.count, 2000)
    }
}
