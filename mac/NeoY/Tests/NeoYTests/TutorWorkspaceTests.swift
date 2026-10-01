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
            runner: NeoYChatGPTPlatformRunner(root: root.appendingPathComponent("missing-platform"))
        )

        _ = try await workspace.bind(
            learner: "maggie",
            threadURL: "https://chatgpt.com/c/test-thread"
        )

        let snapshot = await workspace.snapshot()
        XCTAssertEqual(snapshot.bindings["maggie"]?.threadURL, "https://chatgpt.com/c/test-thread")
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
            runner: NeoYChatGPTPlatformRunner(root: root)
        )
        do {
            _ = try await workspace.bind(learner: "sammy", threadURL: "https://example.com/c/test")
            XCTFail("expected invalid thread URL")
        } catch {
            XCTAssertEqual(error.localizedDescription, "thread_url must be an https://chatgpt.com thread URL")
        }
    }

    func testTurnReportsMissingPlatformDeterministically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-tutor-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = NeoYTutorWorkspace(
            stateURL: root.appendingPathComponent("state.json"),
            runner: NeoYChatGPTPlatformRunner(root: root.appendingPathComponent("missing-platform"))
        )
        _ = try await workspace.bind(
            learner: "maggie",
            threadURL: "https://chatgpt.com/c/test-thread"
        )

        do {
            _ = try await workspace.turn(learner: "maggie", prompt: "hello", files: [])
            XCTFail("expected platform unavailable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ChatGPT browser platform is unavailable"))
        }
    }

    func testRunnerUsesFixedTutorBrowserWorkspace() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-tutor-platform-\(UUID().uuidString)", isDirectory: true)
        let agentWorkspace = root.appendingPathComponent("agent-workspace", isDirectory: true)
        let runner = NeoYChatGPTPlatformRunner(
            root: root,
            agentWorkspace: agentWorkspace,
            workspaceName: "Tutor",
            workspacePoolSize: 4
        )
        XCTAssertEqual(runner.workspaceName, "Tutor")
        XCTAssertEqual(runner.workspacePoolSize, 4)
        XCTAssertEqual(runner.helper.path, agentWorkspace.appendingPathComponent("agent_helpers.py").path)
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
