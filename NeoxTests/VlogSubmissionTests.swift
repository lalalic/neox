import XCTest
@testable import NeoxApp

final class VlogSubmissionTests: XCTestCase {
    func testWriterProducesWatcherCompatibleManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlog-submission-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "submission-test-1"
        let result = try VlogSubmissionWriter.write(
            inboxURL: root,
            submissionID: id,
            instruction: "make a short vlog",
            payloads: [
                VlogSubmissionPayload(filename: "001.jpg", data: Data("image".utf8)),
                VlogSubmissionPayload(filename: "002.mov", data: Data("video".utf8)),
            ]
        )

        let manifestURL = result.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            VlogSubmissionManifest.self,
            from: Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.schema_version, 1)
        XCTAssertEqual(manifest.submission_id, id)
        XCTAssertEqual(manifest.instruction, "make a short vlog")
        XCTAssertEqual(manifest.media.map(\.path), ["media/001.jpg", "media/002.mov"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("media/001.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("media/002.mov").path))
    }

    func testWriterRejectsTraversalAndCleansIncompleteSubmission() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlog-submission-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = "submission-test-2"
        XCTAssertThrowsError(try VlogSubmissionWriter.write(
            inboxURL: root,
            submissionID: id,
            instruction: nil,
            payloads: [VlogSubmissionPayload(filename: "../escape.mov", data: Data("x".utf8))]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
    }
}
