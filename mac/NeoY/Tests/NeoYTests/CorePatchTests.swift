import XCTest
@testable import NeoY

final class CorePatchTests: XCTestCase {
    func testApplyPatchDescriptor() {
        let tool = NeoYPatchTools.tools().first
        XCTAssertEqual(tool?.name, "apply_patch")
        XCTAssertTrue(NeoYCoreRuntime.toolNames.contains("apply_patch"))
    }

    func testCheckThenApplyPatch() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let patch = """
        diff --git a/note.txt b/note.txt
        --- a/note.txt
        +++ b/note.txt
        @@ -1 +1 @@
        -before
        +after
        """
        let service = NeoYPatchService()

        let checked = try decode(service.apply(arguments: args(patch: patch, cwd: directory.path, checkOnly: true)))
        XCTAssertEqual(checked.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before\n")

        let applied = try decode(service.apply(arguments: args(patch: patch, cwd: directory.path)))
        XCTAssertEqual(applied.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")
    }

    func testInvalidPatchReturnsGitFailure() throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try decode(NeoYPatchService().apply(arguments: args(patch: "not a patch\n", cwd: directory.path, checkOnly: true)))
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.stderr.isEmpty)
    }

    private func args(patch: String, cwd: String, checkOnly: Bool = false) -> JSONValue {
        .object([
            "patch": .string(patch),
            "cwd": .string(cwd),
            "check_only": .bool(checkOnly)
        ])
    }

    private func decode(_ value: String) throws -> NeoYPatchResult {
        try JSONDecoder().decode(NeoYPatchResult.self, from: Data(value.utf8))
    }

    private func makeRepository() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q"]
        process.currentDirectoryURL = url
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return url
    }
}
