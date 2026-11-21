import Foundation
import XCTest
@testable import DuplexVoiceKit

private struct FakeSynthesis: SpeechSynthesisProvider {
    func synthesize(_ text: String, language: String) -> AsyncThrowingStream<AudioFrame, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(AudioFrame(pcm16: Data(text.utf8), sampleRate: 16000, channels: 1))
            continuation.finish()
        }
    }
}

private actor RecordingOutput: SpeechAudioOutput {
    private var utterances: [String] = []
    private var stopped = false

    func play(_ audio: AsyncThrowingStream<AudioFrame, Error>) async throws {
        for try await frame in audio {
            try Task.checkCancellation()
            utterances.append(String(decoding: frame.pcm16, as: UTF8.self))
        }
    }
    func stop() async { stopped = true }
    func messages() -> [String] { utterances }
    func wasStopped() -> Bool { stopped }
}

private actor BlockingOutput: SpeechAudioOutput {
    private var waiting: CheckedContinuation<Void, Error>?
    private var stopRequested = false
    private var started = false

    func play(_ audio: AsyncThrowingStream<AudioFrame, Error>) async throws {
        for try await _ in audio {
            started = true
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if stopRequested { continuation.resume(throwing: CancellationError()) }
                else { waiting = continuation }
            }
        }
    }
    func stop() async {
        stopRequested = true
        waiting?.resume(throwing: CancellationError())
        waiting = nil
    }
    func hasStarted() -> Bool { started }
}

final class SpeechQueueTests: XCTestCase {
    func testMergesChineseAndEnglishStreamingSegments() {
        var merger = SentenceMerger()
        XCTAssertEqual(merger.append("你好，"), [])
        XCTAssertEqual(merger.append("今天晴。再"), ["你好，今天晴。"])
        XCTAssertEqual(merger.append("见！"), ["再见！"])
        XCTAssertNil(merger.finish())

        XCTAssertEqual(merger.append("Hello "), [])
        XCTAssertEqual(merger.append("world. Next"), ["Hello world."])
        XCTAssertEqual(merger.finish(), " Next")
    }

    func testBoundedMergeNeverDropsCharacters() {
        var merger = SentenceMerger(maximumCharacters: 16)
        let source = "abcdefghijklmnopqrstuvwxyz123456789"
        let output = merger.append(source) + [merger.finish() ?? ""]
        XCTAssertEqual(output.joined(), source)
        XCTAssertGreaterThan(output.count, 1)
    }

    func testQueueDeduplicatesAndWaitsForFinalPlayback() async throws {
        let output = RecordingOutput()
        let queue = SpeechQueue(synthesis: FakeSynthesis(), output: output, language: "zh-CN")
        try await queue.accept(sequence: 1, text: "你好，")
        try await queue.accept(sequence: 1, text: "你好，")
        try await queue.accept(sequence: 2, text: "今天晴。再见")
        try await queue.complete()
        let finished = await queue.isPlaybackFinished()
        XCTAssertTrue(finished)
        let result = await output.messages()
        XCTAssertEqual(result, ["你好，今天晴。", "再见"])
    }

    func testConflictingAndOutOfOrderFragmentsRejected() async throws {
        let queue = SpeechQueue(synthesis: FakeSynthesis(), output: RecordingOutput())
        do {
            try await queue.accept(sequence: 2, text: "skip")
            XCTFail("accepted missing seq 1")
        } catch SpeechQueueError.invalidSequence(expected: 1, received: 2) {}
        try await queue.accept(sequence: 1, text: "Hello.")
        do {
            try await queue.accept(sequence: 1, text: "Changed.")
            XCTFail("accepted conflicting replay")
        } catch SpeechQueueError.conflictingReplay(sequence: 1) {}
        try await queue.complete()
        do {
            try await queue.accept(sequence: 2, text: "late")
            XCTFail("accepted event after completion")
        } catch SpeechQueueError.alreadyTerminal {}
    }

    func testBargeInStopsPlaybackAndIgnoresLateEvents() async throws {
        let output = BlockingOutput()
        let queue = SpeechQueue(synthesis: FakeSynthesis(), output: output)
        let conversation = VoiceConversation(playback: queue)
        try await conversation.receive(.text(sequence: 1, value: "Hello."))
        for _ in 0..<100 {
            if await output.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let started = await output.hasStarted()
        XCTAssertTrue(started)
        await conversation.userStartedSpeaking()
        do {
            try await queue.complete()
            XCTFail("Interrupted reply completed")
        } catch {
            XCTAssertEqual(error as? SpeechQueueError, .cancelled)
        }
        try await conversation.receive(.text(sequence: 2, value: "Too late."))
        let finished = await queue.isPlaybackFinished()
        XCTAssertFalse(finished)
    }

    func testFailedReplyStaysFailed() async throws {
        let queue = SpeechQueue(synthesis: FakeSynthesis(), output: RecordingOutput())
        await queue.fail("provider unavailable")
        do {
            try await queue.complete()
            XCTFail("finished failed reply")
        } catch SpeechQueueError.upstream(let message) {
            XCTAssertEqual(message, "provider unavailable")
        }
    }
}
