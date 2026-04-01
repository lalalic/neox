import Testing
import XCTest
import CopilotSDK
import WebKitAgent
@testable import Neox

/// Tests for WeChat site adapters dispatched through Neox's AgentCoordinator.
/// Validates the full path: AgentCoordinator → buildTools() → web_agent → site command → WeChat adapters.
@Suite("WeChatAdapter Tests")
@MainActor
struct WeChatAdapterTests {

    let coordinator: AgentCoordinator
    let manager: WebViewManager
    let webAgentTool: ToolDefinition

    init() throws {
        coordinator = AgentCoordinator()
        manager = WebViewManager()
        coordinator.setupWebKitAgent(manager: manager)
        coordinator.registerDefaultTools()

        let tools = coordinator.buildTools()
        guard let tool = tools.first(where: { $0.name == "web_agent" }) else {
            throw TestError("web_agent tool should be registered")
        }
        webAgentTool = tool
    }

    // MARK: - Adapter Listing

    @Test("List all adapters")
    func listAllAdapters() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "action": .string("list")
        ]))
        #expect(result.contains("Available site adapters:"))
        #expect(result.contains("wechat"))
        #expect(result.contains("hackernews"))
    }

    @Test("List WeChat adapters")
    func listWeChatAdapters() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat")
        ]))
        #expect(result.contains("login"))
        #expect(result.contains("status"))
        #expect(result.contains("contacts"))
        #expect(result.contains("send"))
    }

    // MARK: - wechat/login — Navigate to wx.qq.com + detect QR code

    @Test("WeChat login adapter")
    func weChatLoginAdapter() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("login")
        ]))

        #expect(!result.isEmpty, "Login adapter should return result")

        let validStatuses = ["qr_ready", "qr_image", "loading", "logged_in", "status"]
        let hasValidStatus = validStatuses.contains(where: { result.contains($0) })
        #expect(hasValidStatus,
                "Login should return a valid status, got: \(result.prefix(200))")

        #expect(manager.currentURL != nil, "Browser should have navigated to wx.qq.com")
    }

    // MARK: - wechat/status — Check login state (after login adapter navigated)

    @Test("WeChat status after login")
    func weChatStatusAfterLogin() async throws {
        _ = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("login")
        ]))

        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("status")
        ]))

        #expect(!result.isEmpty, "Status adapter should return result")
        let hasStatus = result.contains("status") || result.contains("not_loaded") || result.contains("not_logged_in")
        #expect(hasStatus, "Status should report login state, got: \(result.prefix(200))")
    }

    // MARK: - wechat/contacts — Should report not logged in

    @Test("WeChat contacts not logged in")
    func weChatContactsNotLoggedIn() async throws {
        _ = try await webAgentTool.handler(.object([
            "command": .string("navigate"),
            "url": .string("https://wx.qq.com")
        ]))

        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("contacts")
        ]))

        #expect(!result.isEmpty, "Contacts adapter should return result")
        let isNotLoggedIn = result.contains("error") || result.contains("Not logged in")
            || result.contains("not ready") || result.contains("not_loaded")
            || result.contains("No results")
        #expect(isNotLoggedIn,
                "Contacts should indicate not logged in or empty, got: \(result.prefix(200))")
    }

    // MARK: - Error handling

    @Test("Invalid site adapter")
    func invalidSiteAdapter() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("nonexistent")
        ]))
        #expect(result.contains("Error") || result.contains("not found"),
                "Should error for nonexistent adapter")
    }

    @Test("Site command without params")
    func siteCommandWithoutParams() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site")
        ]))
        #expect(result.contains("Error") || result.contains("site") || result.contains("required"),
                "Should error when 'site' param missing")
    }

    // MARK: - Combined workflow: navigate → snapshot → site adapter

    @Test("Navigate then site status")
    func navigateThenSiteStatus() async throws {
        let navResult = try await webAgentTool.handler(.object([
            "command": .string("navigate"),
            "url": .string("https://wx.qq.com")
        ]))
        #expect(navResult.contains("Page loaded") || navResult.contains("loaded"),
                "Should navigate to wx.qq.com")

        let snapResult = try await webAgentTool.handler(.object([
            "command": .string("snapshot")
        ]))
        #expect(snapResult.contains("Page:") || snapResult.contains("URL:"),
                "Should get page snapshot")

        let statusResult = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("status")
        ]))
        #expect(statusResult.contains("status"),
                "Status adapter should work on already-loaded page")
    }
}

/// Simple error for test setup failures.
private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

/// Relay integration test: Agent uses web_agent site command for WeChat.
/// This test connects to the relay and asks the agent to use the WeChat adapter.
final class WeChatAgentIntegrationTests: XCTestCase {

    var client: CopilotClient!

    override func setUp() async throws {
        try await super.setUp()
        let transport = WebSocketTransport(host: "relay.ai.qili2.com", port: 8765)
        client = CopilotClient(transport: transport)
    }

    override func tearDown() {
        client?.disconnect()
        super.tearDown()
    }

    private func skipIfNoRelay() async throws {
        do {
            try await client.start()
        } catch {
            throw XCTSkip("Cannot reach relay server at relay.ai.qili2.com:8765")
        }
    }

    /// Test that agent can list available site adapters via the relay.
    func testAgentListsAdapters() async throws {
        try await skipIfNoRelay()

        let responseReceived = expectation(description: "Agent sends response")
        responseReceived.assertForOverFulfill = false
        let collector = ResponseContent()

        // Create a simple tool that mimics the site adapter list call
        // (the real web_agent tool needs a WebViewManager which requires @MainActor)
        let tool = ToolDefinition(
            name: "web_agent",
            description: "Browser automation tool with site adapters.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object(["type": .string("string"), "description": .string("Command to execute")]),
                    "site": .object(["type": .string("string"), "description": .string("Site name")]),
                    "action": .object(["type": .string("string"), "description": .string("Action name")])
                ]),
                "required": .array([.string("command")])
            ]),
            skipPermission: true
        ) { args in
            // Simulate adapter list response
            guard case .object(let dict) = args,
                  case .string(let command) = dict["command"],
                  command == "site" else {
                return "Error: unknown command"
            }
            return """
            Available site adapters:

              hackernews:
                - best: Get best Hacker News stories
                - new: Get newest Hacker News stories
                - top: Get top Hacker News stories

              wechat:
                - contacts: Get WeChat contact list (must be logged in) [browser]
                - login: Get WeChat Web login QR code URL [browser]
                - send: Send a WeChat message (must be logged in) [browser]
                - status: Check WeChat Web login status [browser]
            """
        }

        let agent = try await client.createAgent(config: AgentConfig(
            model: "gpt-4.1",
            instructions: """
            You are a test assistant with browser automation capabilities.
            Use the web_agent tool with command="site" and action="list" to list available adapters.
            Then report what adapters are available.
            """,
            tools: [tool],
            onResponse: { message in
                await collector.set(message)
                responseReceived.fulfill()
            },
            onAskUser: { _ in return "No more tasks." }
        ))

        let agentTask = Task {
            try await agent.start(prompt: "List all available site adapters using the web_agent tool with command='site' and action='list'. Then tell me what wechat adapters are available.")
        }

        await fulfillment(of: [responseReceived], timeout: 120)
        agent.stop()
        agentTask.cancel()

        let content = await collector.value
        XCTAssertNotNil(content, "Should receive a response")
        XCTAssertTrue(content?.lowercased().contains("wechat") == true,
                      "Response should mention wechat adapters, got: \(content ?? "nil")")
    }
}

// MARK: - Helpers

private actor ResponseContent {
    var value: String?
    func set(_ v: String) { value = v }
}
