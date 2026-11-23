import XCTest
import AVFoundation
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

    func testDeniedSpeechPermissionStaysForegroundWithRecoverableError() async {
        let dictation = ChatComposerDictation(
            speechPermission: { false },
            microphonePermission: { true })

        dictation.toggle()
        await waitUntil { !dictation.isStarting }

        XCTAssertFalse(dictation.isRecording)
        XCTAssertEqual(dictation.errorText, "Speech Recognition permission is required.")
    }

    func testDeniedMicrophonePermissionStaysForegroundWithRecoverableError() async {
        let dictation = ChatComposerDictation(
            speechPermission: { true },
            microphonePermission: { false })

        dictation.toggle()
        await waitUntil { !dictation.isStarting }

        XCTAssertFalse(dictation.isRecording)
        XCTAssertEqual(dictation.errorText, "Microphone permission is required.")
    }

    func testRapidSecondTapCancelsPendingStartup() async {
        let dictation = ChatComposerDictation(
            speechPermission: {
                try? await Task.sleep(for: .milliseconds(50))
                return true
            },
            microphonePermission: { true })

        dictation.toggle()
        XCTAssertTrue(dictation.isStarting)
        dictation.toggle()
        XCTAssertFalse(dictation.isStarting)

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(dictation.isRecording)
    }

    func testStopAllowsFreshStartupAttempt() async {
        let dictation = ChatComposerDictation(
            speechPermission: { false },
            microphonePermission: { true })

        dictation.toggle()
        XCTAssertTrue(dictation.isStarting)
        dictation.stop()
        XCTAssertFalse(dictation.isStarting)

        dictation.toggle()
        await waitUntil { !dictation.isStarting }

        XCTAssertFalse(dictation.isRecording)
        XCTAssertEqual(dictation.errorText, "Speech Recognition permission is required.")
    }

    func testStopClearsRecoverableErrorDuringTeardown() async {
        let dictation = ChatComposerDictation(
            speechPermission: { false },
            microphonePermission: { true })

        dictation.toggle()
        await waitUntil { !dictation.isStarting }
        XCTAssertNotNil(dictation.errorText)

        dictation.stop()

        XCTAssertNil(dictation.errorText)
        XCTAssertFalse(dictation.isStarting)
        XCTAssertFalse(dictation.isRecording)
    }

    func testInputFormatGuardRejectsMissingSampleRateOrChannels() {
        XCTAssertFalse(ChatComposerDictation.inputFormatIsUsable(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(ChatComposerDictation.inputFormatIsUsable(sampleRate: .infinity, channelCount: 1))
        XCTAssertFalse(ChatComposerDictation.inputFormatIsUsable(sampleRate: 48_000, channelCount: 0))
        XCTAssertTrue(ChatComposerDictation.inputFormatIsUsable(sampleRate: 48_000, channelCount: 1))
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous dictation state")
    }
}
