import XCTest

@testable import NeoY

final class TutorWorkspaceTests: XCTestCase {
    func testBindingPersistsWithoutTranscriptState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-tutor-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("tutor-workspace.json")
        let workspace = NeoYTutorWorkspace(
            stateURL: stateURL,
            runner: NeoYChatGPTPlatformRunner()
        )

        _ = try await workspace.bind(
            learner: "maggie",
            threadURL: "https://chatgpt.com/c/test-thread"
        )

        let snapshot = await workspace.snapshot()
        XCTAssertEqual(snapshot.bindings["maggie"]?.threadURL, "https://chatgpt.com/c/test-thread")
        XCTAssertNil(snapshot.bindings["maggie"]?.projectID)
        XCTAssertNil(snapshot.bindings["maggie"]?.projectURL)
        XCTAssertNil(snapshot.bindings["maggie"]?.targetID)

        let bytes = try Data(contentsOf: stateURL)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("maggie"))
        XCTAssertTrue(text.contains("test-thread"))
        XCTAssertFalse(text.contains("transcript"))
        XCTAssertFalse(text.contains("messages"))
    }

    func testBindingRejectsNonChatGPTURL() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-tutor-tests-\(UUID().uuidString)", isDirectory: true)
        let workspace = NeoYTutorWorkspace(
            stateURL: root.appendingPathComponent("state.json"),
            runner: NeoYChatGPTPlatformRunner()
        )
        do {
            _ = try await workspace.bind(learner: "sammy", threadURL: "https://example.com/c/test")
            XCTFail("expected invalid thread URL")
        } catch {
            XCTAssertEqual(error.localizedDescription, "thread_url must be an https://chatgpt.com thread URL")
        }
    }

    func testBrowserWorkspaceSessionLifecycleIsExplicit() {
        let source = try! String(contentsOfFile: #filePath.replacingOccurrences(
            of: "/Tests/NeoYTests/TutorWorkspaceTests.swift",
            with: "/Sources/NeoY/BrowserWorkspace.swift"
        ))
        XCTAssertTrue(source.contains("browser-workspace create"))
        XCTAssertTrue(source.contains("browser-workspace session start"))
        XCTAssertTrue(source.contains("browser-workspace session exec"))
        XCTAssertTrue(source.contains("browser-workspace session stop"))
        XCTAssertTrue(source.contains("from platform_runner import action_path, prepare_action"))
    }

    func testRunnerUsesFixedTutorBrowserWorkspace() {
        let runner = NeoYChatGPTPlatformRunner(
            workspaceName: "Tutor",
            workspacePoolSize: 4
        )
        XCTAssertEqual(runner.workspaceName, "Tutor")
        XCTAssertEqual(runner.workspacePoolSize, 4)
        XCTAssertEqual(runner.platformCommand, "browser-workspace")
    }

    func testTutorRunnerUsesFamilyTutorAppName() {
        let source = try! String(contentsOfFile: #filePath.replacingOccurrences(
            of: "/Tests/NeoYTests/TutorWorkspaceTests.swift",
            with: "/Sources/NeoY/TutorWorkspace.swift"
        ))
        XCTAssertTrue(source.contains("\"app\": \"tutor\""))
    }

    func testRunnerDoesNotPersistSessionScopedTarget() {
        let source = try! String(contentsOfFile: #filePath.replacingOccurrences(
            of: "/Tests/NeoYTests/TutorWorkspaceTests.swift",
            with: "/Sources/NeoY/TutorWorkspace.swift"
        ))
        XCTAssertTrue(source.contains("targetID: nil"))
        XCTAssertFalse(source.contains("BH_AGENT_WORKSPACE"))
        XCTAssertFalse(source.contains("browser-platforms"))
    }

    func testRemoteFeatureMatchesTutorTools() {
        XCTAssertTrue(NeoYRemoteFeature.tutor.matches(toolName: "tutor.workspace"))
        XCTAssertFalse(NeoYRemoteFeature.tutor.matches(toolName: "phone.status"))
    }

    func testTutorToolSurfaceIsSingleFixedWorkspaceTool() {
        let tools = NeoYTutorTools.tools()
        XCTAssertEqual(tools.map(\.name), ["tutor.workspace"])
    }
}
