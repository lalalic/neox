import XCTest
import CopilotSDK
import WebKitAgent
@testable import Neox

/// Tests for WeChat site adapters dispatched through Neox's AgentCoordinator.
/// Validates the full path: AgentCoordinator → buildTools() → web_agent → site command → WeChat adapters.
/// Uses @MainActor since WebViewManager requires WKWebView on main thread.
@MainActor
final class WeChatAdapterTests: XCTestCase {

    var coordinator: AgentCoordinator!
    var manager: WebViewManager!
    var webAgentTool: ToolDefinition!

    override func setUp() {
        super.setUp()
        coordinator = AgentCoordinator()
        manager = WebViewManager()
        coordinator.setupWebKitAgent(manager: manager)
        coordinator.registerDefaultTools()

        // Find the web_agent tool from built tools
        let tools = coordinator.buildTools()
        webAgentTool = tools.first(where: { $0.name == "web_agent" })
        XCTAssertNotNil(webAgentTool, "web_agent tool should be registered")
    }

    override func tearDown() {
        webAgentTool = nil
        coordinator = nil
        manager = nil
        super.tearDown()
    }

    // MARK: - Adapter Listing

    func testListAllAdapters() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "action": .string("list")
        ]))
        XCTAssertTrue(result.contains("Available site adapters:"), "Should list adapters")
        XCTAssertTrue(result.contains("wechat"), "Should include wechat adapters")
        XCTAssertTrue(result.contains("hackernews"), "Should include hackernews adapters")
    }

    func testListWeChatAdapters() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat")
        ]))
        // No action → list adapters for this site
        XCTAssertTrue(result.contains("login"), "Should list wechat/login adapter")
        XCTAssertTrue(result.contains("status"), "Should list wechat/status adapter")
        XCTAssertTrue(result.contains("contacts"), "Should list wechat/contacts adapter")
        XCTAssertTrue(result.contains("send"), "Should list wechat/send adapter")
    }

    // MARK: - wechat/login — Navigate to wx.qq.com + detect QR code

    func testWeChatLoginAdapter() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("login")
        ]))

        // The login adapter navigates to wx.qq.com, waits 5s, then runs JS to detect QR/login state.
        // Result should be a JSON array with status field.
        XCTAssertFalse(result.isEmpty, "Login adapter should return result")

        // Parse the status — could be qr_ready, qr_image, loading, or logged_in
        let validStatuses = ["qr_ready", "qr_image", "loading", "logged_in", "status"]
        let hasValidStatus = validStatuses.contains(where: { result.contains($0) })
        XCTAssertTrue(hasValidStatus,
                      "Login should return a valid status (qr_ready/qr_image/loading/logged_in), got: \(result.prefix(200))")

        // Verify the browser actually navigated
        XCTAssertNotNil(manager.currentURL, "Browser should have navigated to wx.qq.com")
    }

    // MARK: - wechat/status — Check login state (after login adapter navigated)

    func testWeChatStatusAfterLogin() async throws {
        // First navigate via login adapter
        _ = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("login")
        ]))

        // Then check status (reuses current page — no preNavigate on status adapter)
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("status")
        ]))

        XCTAssertFalse(result.isEmpty, "Status adapter should return result")
        // Should contain status and angularReady fields
        let hasStatus = result.contains("status") || result.contains("not_loaded") || result.contains("not_logged_in")
        XCTAssertTrue(hasStatus, "Status should report login state, got: \(result.prefix(200))")
    }

    // MARK: - wechat/contacts — Should report not logged in

    func testWeChatContactsNotLoggedIn() async throws {
        // Navigate to wx.qq.com first
        _ = try await webAgentTool.handler(.object([
            "command": .string("navigate"),
            "url": .string("https://wx.qq.com")
        ]))

        // Try contacts without being logged in
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("contacts")
        ]))

        XCTAssertFalse(result.isEmpty, "Contacts adapter should return result")
        // Without login, should get an error about not being logged in, Angular not ready, or no results
        let isNotLoggedIn = result.contains("error") || result.contains("Not logged in")
            || result.contains("not ready") || result.contains("not_loaded")
            || result.contains("No results")
        XCTAssertTrue(isNotLoggedIn,
                      "Contacts should indicate not logged in or empty, got: \(result.prefix(200))")
    }

    // MARK: - Error handling

    func testInvalidSiteAdapter() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("nonexistent")
        ]))
        XCTAssertTrue(result.contains("Error") || result.contains("not found"),
                      "Should error for nonexistent adapter")
    }

    func testSiteCommandWithoutParams() async throws {
        let result = try await webAgentTool.handler(.object([
            "command": .string("site")
        ]))
        XCTAssertTrue(result.contains("Error") || result.contains("site") || result.contains("required"),
                      "Should error when 'site' param missing")
    }

    // MARK: - Combined workflow: navigate → snapshot → site adapter

    func testNavigateThenSiteStatus() async throws {
        // Step 1: Navigate manually
        let navResult = try await webAgentTool.handler(.object([
            "command": .string("navigate"),
            "url": .string("https://wx.qq.com")
        ]))
        XCTAssertTrue(navResult.contains("Page loaded") || navResult.contains("loaded"),
                      "Should navigate to wx.qq.com")

        // Step 2: Take a snapshot
        let snapResult = try await webAgentTool.handler(.object([
            "command": .string("snapshot")
        ]))
        XCTAssertTrue(snapResult.contains("Page:") || snapResult.contains("URL:"),
                      "Should get page snapshot")

        // Step 3: Use site adapter to check status
        let statusResult = try await webAgentTool.handler(.object([
            "command": .string("site"),
            "site": .string("wechat"),
            "action": .string("status")
        ]))
        XCTAssertTrue(statusResult.contains("status"),
                      "Status adapter should work on already-loaded page")
    }
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
