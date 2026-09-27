import XCTest
@testable import NeoY

final class DemoRuntimeTests: XCTestCase {
    @MainActor
    func testSharedPrimitiveContractAndTimeline() throws {
        XCTAssertEqual(Set(DemoPrimitive.allCases.map(\.rawValue)), Set([
            "step", "spotlight", "annotate", "caption", "say", "cursor", "highlight",
            "clear", "pause", "resume", "wait", "start_recording", "stop_recording",
        ]))

        let fixedNow = Date(timeIntervalSince1970: 100)
        let timeline = DemoTimeline(clock: { fixedNow })
        timeline.start()
        let rect = DemoTarget(rect: CGRect(x: 1, y: 2, width: 3, height: 4))
        for primitive in [DemoPrimitive.step, .spotlight, .annotate, .caption, .say, .cursor, .highlight, .clear] {
            _ = try timeline.record(primitive, target: rect, text: primitive.rawValue, durationMS: 10)
        }
        _ = try timeline.record(.pause, status: "paused")
        XCTAssertTrue(timeline.isPaused)
        _ = try timeline.record(.resume, status: "resumed")
        XCTAssertFalse(timeline.isPaused)
        _ = try timeline.record(.wait, durationMS: 20)
        let events = timeline.finish(outputReference: "/files/demo.mov")
        XCTAssertEqual(events.first?.primitive, .startRecording)
        XCTAssertEqual(events.last?.primitive, .stopRecording)
        XCTAssertEqual(events.map(\.sequence), Array(0..<events.count))
    }

    func testExplicitRectangleTargetRoundTrips() throws {
        let original = DemoTarget(rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DemoTarget.self, from: data), original)
        XCTAssertEqual(original.summary, "rect(10,20,30,40)")
    }
}
