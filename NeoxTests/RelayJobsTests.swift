import XCTest
@testable import NeoxApp

final class RelayJobsTests: XCTestCase {
    func testJobsAreMetadataOnly() throws {
        let job = try XCTUnwrap(RelayJob(wire: [
            "id": "902", "title": "Vlog export", "repository": "lalalic/neo",
            "status": "RUNNING", "updatedAt": "2026-11-08T16:40:00Z",
            "prompt": "private request", "objective": "secret"
        ]))
        XCTAssertEqual(job.id, "902")
        XCTAssertEqual(job.displayTitle, "Vlog export")
        XCTAssertEqual(job.statusName, "Running")
        XCTAssertTrue(job.isActive)
        XCTAssertFalse(String(describing: job).contains("private request"))
        XCTAssertFalse(String(describing: job).contains("secret"))
    }

    func testCompletedJobAndMalformedInput() throws {
        let job = try XCTUnwrap(RelayJob(wire: ["id": "111", "status": "COMPLETED"]))
        XCTAssertFalse(job.isActive)
        XCTAssertEqual(job.displayTitle, "Job 111")
        XCTAssertNil(RelayJob(wire: ["title": "Missing id", "status": "RUNNING"]))
        XCTAssertNil(RelayJob(wire: ["id": "42", "status": ""]))
    }
}
