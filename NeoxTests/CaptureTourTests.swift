import XCTest
@testable import NeoxApp

@MainActor
final class CaptureTourTests: XCTestCase {
    func testManifestValidationRejectsDuplicateShots() {
        let shot = CaptureShot(id: "same", title: "One")
        XCTAssertThrowsError(try CaptureTourManifest(tourID: "tour", title: "Test", shots: [shot, shot]).validated())
    }

    func testSessionTransitionsToCompletionAfterAllResults() throws {
        let store = CaptureTourStore()
        let manifest = CaptureTourManifest(tourID: "tour", title: "Test", shots: [CaptureShot(id: "one", title: "One")])
        let session = try store.start(manifest)
        var completed = session
        completed.results = [CaptureResult(shotID: "one", status: "accepted", takeCount: 1, actualDurationS: 1, createdAt: Date(), mediaReference: nil, qualityWarnings: [])]
        completed.currentIndex = 1
        completed.state = "completed"
        store.update(completed)
        XCTAssertTrue(store.statusJSON().contains("\"state\":\"completed\""))
    }
}
