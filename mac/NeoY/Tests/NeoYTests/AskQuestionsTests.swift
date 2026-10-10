import Foundation
import XCTest

@testable import NeoY

final class AskQuestionsTests: XCTestCase {
    @MainActor
    func testRegistersIntentToolsAndPrivateResource() throws {
        let server = MCPServer(name: "test", port: 0)
        AskQuestions.register(on: server)
        let data = Data(server.toolDescriptorsJSON.utf8)
        let tools = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), [AskQuestions.toolName, AskQuestions.submitToolName, AskQuestions.cancelToolName])
        XCTAssertEqual(server.resourceURIs, [AskQuestions.resourceURI])
        let ask = try XCTUnwrap(tools.first { $0["name"] as? String == AskQuestions.toolName })
        let meta = try XCTUnwrap(ask["_meta"] as? [String: Any])
        XCTAssertEqual((meta["ui"] as? [String: Any])?["resourceUri"] as? String, AskQuestions.resourceURI)
        let submit = try XCTUnwrap(tools.first { $0["name"] as? String == AskQuestions.submitToolName })
        XCTAssertEqual(((submit["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["visibility"] as? [String], ["app"])
    }

    @MainActor
    func testAskResultContainsCorrelatedPromptAndContinuationLimitation() async throws {
        let server = MCPServer(name: "test", port: 0)
        AskQuestions.register(on: server)
        let result = try await server.invokeRegisteredTool(AskQuestions.toolName, arguments: .object(["prompt": .string("# Choose\n- **A** or B")]))
        let object = try resultObject(result)
        let structured = try XCTUnwrap(object["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["prompt"] as? String, "# Choose\n- **A** or B")
        XCTAssertEqual(structured["prompt_html"] as? String, AskQuestions.renderMarkdown("# Choose\n- **A** or B"))
        XCTAssertNotNil(structured["session_id"] as? String)
        XCTAssertTrue((structured["continuation"] as? String)?.contains("new MCP turn") == true)
    }

    func testMarkdownEscapesMarkupAndKeepsBasicStructure() {
        let html = AskQuestions.renderMarkdown("# Hello\n\n- **safe**\n\n<script>alert(1)</script>")
        XCTAssertTrue(html.contains("<h1>Hello</h1>"))
        XCTAssertTrue(html.contains("<ul><li><strong>safe</strong></li></ul>"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testResourceUsesPrivateMCPAppsMetadataAndHandshake() throws {
        let object = try resultObject(AskQuestions.resourceResult())
        XCTAssertEqual(object["ttlMs"] as? Int, 0)
        XCTAssertEqual(object["cacheScope"] as? String, "private")
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.first?["mimeType"] as? String, AskQuestions.mimeType)
        XCTAssertTrue(AskQuestions.html.contains("ui/initialize"))
        XCTAssertTrue(AskQuestions.html.contains("ui/notifications/initialized"))
        XCTAssertTrue(AskQuestions.html.contains(AskQuestions.submitToolName))
        XCTAssertTrue(AskQuestions.html.contains("promptEl.innerHTML=d.prompt_html"))
    }

    func testAskQuestionsIsRemoteCatalogableAndAppOnlyToolsFollowTheirIntent() {
        let catalog = Set(NeoYRemoteToolCatalog.availableToolNames(configuration: NeoYControlPlaneConfiguration()))
        XCTAssertTrue(catalog.isSuperset(of: NeoYRemoteToolCatalog.askQuestionsToolNames))
        XCTAssertEqual(
            NeoYRemoteToolCatalog.remoteTools(for: [AskQuestions.toolName]),
            NeoYRemoteToolCatalog.askQuestionsToolNames
        )
        let unrelatedRemoteTools = NeoYRemoteToolCatalog.remoteTools(for: [
            "shell", AskQuestions.submitToolName, AskQuestions.cancelToolName,
        ])
        XCTAssertTrue(unrelatedRemoteTools.contains("shell"))
        XCTAssertTrue(unrelatedRemoteTools.isDisjoint(with: NeoYRemoteToolCatalog.askQuestionsToolNames))
    }

    @MainActor
    func testSubmissionIsCorrelatedOneShotAndIsolationIsEnforced() async throws {
        let server = MCPServer(name: "test", port: 0)
        AskQuestions.register(on: server)
        let created = try await server.invokeRegisteredTool(AskQuestions.toolName, arguments: .object(["prompt": .string("Question A")]))
        let session = try XCTUnwrap(try resultObject(created)["structuredContent"] as? [String: Any])
        let id = try XCTUnwrap(session["session_id"] as? String)
        let submitted = try await server.invokeRegisteredTool(AskQuestions.submitToolName, arguments: .object(["session_id": .string(id), "answer": .string("answer A")]))
        XCTAssertEqual((try resultObject(submitted)["structuredContent"] as? [String: Any])?["answer"] as? String, "answer A")
        do {
            _ = try await server.invokeRegisteredTool(AskQuestions.submitToolName, arguments: .object(["session_id": .string(id), "answer": .string("answer again")]))
            XCTFail("second submission should be rejected")
        } catch { }
        do {
            _ = try await server.invokeRegisteredTool(AskQuestions.submitToolName, arguments: .object(["session_id": .string(UUID().uuidString), "answer": .string("wrong session")]))
            XCTFail("unknown session should be rejected")
        } catch { }

        let cancelled = try await server.invokeRegisteredTool(AskQuestions.toolName, arguments: .object(["prompt": .string("Question B")]))
        let cancelledID = try XCTUnwrap((try resultObject(cancelled)["structuredContent"] as? [String: Any])?["session_id"] as? String)
        _ = try await server.invokeRegisteredTool(AskQuestions.cancelToolName, arguments: .object(["session_id": .string(cancelledID)]))
        do {
            _ = try await server.invokeRegisteredTool(AskQuestions.submitToolName, arguments: .object(["session_id": .string(cancelledID), "answer": .string("late")]))
            XCTFail("cancelled session should be rejected")
        } catch { }
    }

    @MainActor
    func testRemotePrincipalBindingRejectsAnotherCaller() async throws {
        let server = MCPServer(name: "test", port: 0)
        AskQuestions.register(on: server)
        let created = try await AskQuestions.$requestPrincipal.withValue("principal-A") {
            try await server.invokeRegisteredTool(AskQuestions.toolName, arguments: .object(["prompt": .string("Private question")]))
        }
        let data = try resultObject(created)
        let session = try XCTUnwrap(data["structuredContent"] as? [String: Any])
        let id = try XCTUnwrap(session["session_id"] as? String)
        let args: JSONValue = .object(["session_id": .string(id), "answer": .string("private answer")])
        do {
            _ = try await AskQuestions.$requestPrincipal.withValue("principal-B") {
                try await server.invokeRegisteredTool(AskQuestions.submitToolName, arguments: args)
            }
            XCTFail("another authenticated caller must not submit")
        } catch { }
        let submitted = try await AskQuestions.$requestPrincipal.withValue("principal-A") {
            try await server.invokeRegisteredTool(AskQuestions.submitToolName, arguments: args)
        }
        XCTAssertEqual((try resultObject(submitted)["structuredContent"] as? [String: Any])?["status"] as? String, "submitted")
    }

    func testWidgetKeepsSubmittedStateAfterMessageFailure() {
        XCTAssertTrue(AskQuestions.html.contains("Retry notification"))
        XCTAssertTrue(AskQuestions.html.contains("window.addEventListener('pagehide'"))
        XCTAssertTrue(AskQuestions.html.contains("if(response?.isError)"))
    }

    private func resultObject(_ encoded: String) throws -> [String: Any] {
        XCTAssertTrue(encoded.hasPrefix("mcpresult:"))
        let data = try XCTUnwrap(Data(base64Encoded: String(encoded.dropFirst("mcpresult:".count))))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

}
