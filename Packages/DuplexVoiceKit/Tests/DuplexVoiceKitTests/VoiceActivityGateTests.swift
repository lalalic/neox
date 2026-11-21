import Foundation
import XCTest
@testable import DuplexVoiceKit

final class VoiceActivityGateTests: XCTestCase {
    private func frame(_ value: Int16) -> AudioFrame {
        let samples = [Int16](repeating: value, count: 160)
        return AudioFrame(pcm16: samples.withUnsafeBytes { Data($0) }, sampleRate: 16_000, channels: 1)
    }

    func testSpeechNeedsMinimumEnergyAndEndsAfterSilence() {
        var gate = VoiceActivityGate(threshold: 0.02, minimumSpeechMilliseconds: 90, silenceMilliseconds: 200)
        for _ in 0..<8 { XCTAssertNil(gate.consume(frame(2500))) }
        XCTAssertEqual(gate.consume(frame(2500)), .started)
        XCTAssertTrue(gate.isSpeaking)
        for _ in 0..<19 { XCTAssertNil(gate.consume(frame(0))) }
        XCTAssertEqual(gate.consume(frame(0)), .ended)
        XCTAssertFalse(gate.isSpeaking)
    }

    func testQuietNoiseNeverArms() {
        var gate = VoiceActivityGate()
        for _ in 0..<300 { XCTAssertNil(gate.consume(frame(200))) }
        XCTAssertFalse(gate.isSpeaking)
    }
}
