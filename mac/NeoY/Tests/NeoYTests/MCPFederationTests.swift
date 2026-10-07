import Darwin
import XCTest

@testable import NeoY

final class MCPFederationTests: XCTestCase {
    func testBundledAuthorizationAndRealCallsWithoutLegacyLatch() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let client = NeoYMCPStdioClient(
            executable: fixture.node, arguments: [fixture.server.path],
            environment: NeoYBundledRuntime.coreEnvironment,
            retryDelays: [.milliseconds(10)]
        )
        defer { Task { await client.stop() } }

        let snapshot = try await client.connect()
        XCTAssertTrue(Set(snapshot.tools.map(\.name)).isSuperset(of: ["fs", "shell", "apply_patch"]))

        let file = fixture.root.appendingPathComponent("sample.txt")
        try Data("before\n".utf8).write(to: file)
        let readResult = try await client.call(name: "fs", arguments: .object([
            "command": .string("read"),
            "args": .object(["path": .string(file.path)])
        ]))
        XCTAssertTrue(try Self.text(readResult).contains("before"))
        let shellResult = try await client.call(name: "shell", arguments: .object([
            "command": .string("exec"),
            "args": .object(["command": .string("printf lifecycle-ok")])
        ]))
        XCTAssertTrue(try Self.text(shellResult).contains("lifecycle-ok"))

        let patch = """
        diff --git a/sample.txt b/sample.txt
        --- a/sample.txt
        +++ b/sample.txt
        @@ -1 +1 @@
        -before
        +after

        """
        _ = try await client.call(name: "apply_patch", arguments: .object([
            "patch": .string(patch), "cwd": .string(fixture.root.path)
        ]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after\n")

        let unauthorized = NeoYMCPStdioClient(
            executable: fixture.node, arguments: [fixture.server.path], retryDelays: [.seconds(5)]
        )
        await XCTAssertThrowsErrorAsync { _ = try await unauthorized.connect() }
        await unauthorized.stop()
    }

    func testUnexpectedAndRepeatedChildExitsRecoverWithoutDuplicateTools() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = await MainActor.run { MCPServer(name: "test", port: 0) }
        let federation = await MainActor.run { NeoYMCPFederation(server: server) }
        let configuration = NeoYMCPServerConfiguration(
            name: NeoYBundledRuntime.coreProviderName,
            url: Self.stdioURL(node: fixture.node, script: fixture.server.path),
            isEnabled: true
        )
        await federation.reconcile([configuration])
        defer { Task { @MainActor in federation.stop() } }

        for _ in 0..<3 {
            let pid = await federation.stdioProcessIdentifier(configuration.name)
            let originalPID = try XCTUnwrap(pid)
            XCTAssertEqual(kill(originalPID, SIGKILL), 0)
            let replacementPID = try await Self.waitForPID(federation, name: configuration.name, unlike: originalPID)
            XCTAssertNotEqual(replacementPID, originalPID)
            let statuses = await federation.statuses(configurations: [configuration])
            let status = try XCTUnwrap(statuses.first)
            XCTAssertTrue(status.healthy)
            XCTAssertEqual(status.lifecycleState, "ready")
            XCTAssertTrue(status.processAlive)
            XCTAssertTrue(status.transportConnected)
            XCTAssertTrue(status.initialized)
            XCTAssertTrue(status.toolsListSuccessful)
            let names = await MainActor.run { server.toolNames }
            XCTAssertEqual(names.count, Set(names).count)
            XCTAssertTrue(Set(names).isSuperset(of: ["fs", "shell", "apply_patch"]))
        }
    }

    func testExternalProviderPublishesOneCommandFacade() async throws {
        let fixture = try Self.makeFixture(requireCoreAuthorization: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = await MainActor.run { MCPServer(name: "test", port: 0) }
        let federation = await MainActor.run { NeoYMCPFederation(server: server) }
        let configuration = NeoYMCPServerConfiguration(
            name: "events",
            url: Self.stdioURL(node: fixture.node, script: fixture.server.path),
            isEnabled: true
        )
        await federation.reconcile([configuration])
        defer { Task { @MainActor in federation.stop() } }

        let names = await MainActor.run { server.toolNames }
        XCTAssertEqual(names, ["events"])
        let statuses = await federation.statuses(configurations: [configuration])
        XCTAssertEqual(statuses.first?.exposedTools, ["events"])
    }

    func testDirectFederatedToolAuthorizationUsesRegisteredProviderOwnership() {
        XCTAssertEqual(
            MCPServer.remoteProvider(
                forToolName: "markcut.preview",
                ownership: ["markcut.preview": "markcut"]
            ),
            "markcut"
        )
        XCTAssertNil(MCPServer.remoteProvider(forToolName: "markcut.preview", ownership: [:]))
        XCTAssertEqual(
            MCPServer.remoteProvider(forToolName: "mcp.events.preview", ownership: [:]),
            "events"
        )
    }

    func testExternalProviderExposesUIChildWithRewrittenMetadataAndRoutesCalls() async throws {
        let fixture = try Self.makeFixture(requireCoreAuthorization: false, includeUIMetadata: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = await MainActor.run { MCPServer(name: "test", port: 0) }
        let federation = await MainActor.run { NeoYMCPFederation(server: server) }
        let configuration = NeoYMCPServerConfiguration(
            name: "markcut",
            url: Self.stdioURL(node: fixture.node, script: fixture.server.path),
            isEnabled: true
        )
        await federation.reconcile([configuration])
        defer { Task { @MainActor in federation.stop() } }

        let names = await MainActor.run { server.toolNames }
        XCTAssertEqual(names, ["markcut.output", "markcut.preview", "markcut.preview.submit", "mcp.markcut"])
        let descriptorData = await MainActor.run { Data(server.toolDescriptorsJSON.utf8) }
        let descriptors = try XCTUnwrap(try JSONSerialization.jsonObject(with: descriptorData) as? [[String: Any]])
        let preview = try XCTUnwrap(descriptors.first { $0["name"] as? String == "markcut.preview" })
        let previewMeta = try XCTUnwrap(preview["_meta"] as? [String: Any])
        let previewUI = try XCTUnwrap(previewMeta["ui"] as? [String: Any])
        XCTAssertTrue((previewUI["resourceUri"] as? String)?.hasPrefix("ui://markcut/") == true)

        let action = try XCTUnwrap(descriptors.first { $0["name"] as? String == "markcut.preview.submit" })
        let actionMeta = try XCTUnwrap(action["_meta"] as? [String: Any])
        let actionUI = try XCTUnwrap(actionMeta["ui"] as? [String: Any])
        XCTAssertEqual(actionUI["visibility"] as? [String], ["app"])
        XCTAssertTrue((actionMeta["ui/resourceUri"] as? String)?.hasPrefix("ui://markcut/") == true)

        let output = try XCTUnwrap(descriptors.first { $0["name"] as? String == "markcut.output" })
        let outputMeta = try XCTUnwrap(output["_meta"] as? [String: Any])
        XCTAssertTrue((outputMeta["openai/outputTemplate"] as? String)?.hasPrefix("ui://markcut/") == true)

        let result = try await server.invokeRegisteredTool("markcut.preview", arguments: .object([:]))
        XCTAssertTrue(try Self.text(result).contains("preview-called"))

        let facadeHelp = try await server.invokeRegisteredTool("mcp.markcut", arguments: .object([
            "command": .string("help")
        ]))
        XCTAssertFalse(facadeHelp.contains("preview.submit"))
        let submit = try await server.invokeRegisteredTool("markcut.preview.submit", arguments: .object([:]))
        XCTAssertTrue(try Self.text(submit).contains("submit-called"))
    }

    func testExternalProviderRemovalUnregistersUIChildToolsAndResources() async throws {
        let fixture = try Self.makeFixture(requireCoreAuthorization: false, includeUIMetadata: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = await MainActor.run { MCPServer(name: "test", port: 0) }
        let federation = await MainActor.run { NeoYMCPFederation(server: server) }
        let configuration = NeoYMCPServerConfiguration(
            name: "markcut",
            url: Self.stdioURL(node: fixture.node, script: fixture.server.path),
            isEnabled: true
        )
        await federation.reconcile([configuration])
        let resourcesBeforeRemoval = await MainActor.run { server.resourceURIs }
        XCTAssertFalse(resourcesBeforeRemoval.isEmpty)
        await federation.reconcile([])
        let toolsAfterRemoval = await MainActor.run { server.toolNames }
        let resourcesAfterRemoval = await MainActor.run { server.resourceURIs }
        XCTAssertEqual(toolsAfterRemoval, [])
        XCTAssertEqual(resourcesAfterRemoval, [])
    }

    func testStartupFailureBacksOffAndRecoversWhenCauseClears() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let failure = fixture.root.appendingPathComponent("fail-startup")
        try Data().write(to: failure)
        let client = NeoYMCPStdioClient(
            executable: fixture.node, arguments: [fixture.server.path],
            environment: NeoYBundledRuntime.coreEnvironment.merging([
                "FAKE_MCP_FAIL_FILE": failure.path
            ]) { _, supplied in supplied },
            retryDelays: [.milliseconds(20), .milliseconds(50)]
        )
        defer { Task { await client.stop() } }

        await XCTAssertThrowsErrorAsync { _ = try await client.connect() }
        try FileManager.default.removeItem(at: failure)
        _ = try await Self.waitForPID(client)
        let recoveryResult = try await client.call(name: "shell", arguments: .object([
            "command": .string("exec"),
            "args": .object(["command": .string("printf recovered")])
        ]))
        XCTAssertTrue(try Self.text(recoveryResult).contains("recovered"))
    }

    private struct Fixture {
        let root: URL
        let node: String
        let server: URL
    }

    private static func makeFixture(requireCoreAuthorization: Bool = true, includeUIMetadata: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-stdio-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = root.appendingPathComponent("fake-mcp.mjs")
        let source = #"""
        import fs from "node:fs";
        import readline from "node:readline";
        import { spawnSync } from "node:child_process";
        const requireCoreAuthorization = __REQUIRE_CORE_AUTH__;
        const includeUIMetadata = __INCLUDE_UI_METADATA__;
        if (requireCoreAuthorization && process.env.NEO_CORE_FULL_ACCESS_ACK !== "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS") process.exit(78);
        if (process.env.FAKE_MCP_FAIL_FILE && fs.existsSync(process.env.FAKE_MCP_FAIL_FILE)) process.exit(70);
        const tools = ["fs", "shell", "apply_patch"].map(name => ({
          name, description: name, inputSchema: { type: "object", properties: {} }
        })).concat(includeUIMetadata ? [
          { name: "preview", description: "Preview", inputSchema: { type: "object", properties: {} }, _meta: { ui: { resourceUri: "ui://markcut/preview.html" } } },
          { name: "markcut.preview.submit", description: "Submit", inputSchema: { type: "object", properties: {} }, _meta: { "ui/resourceUri": "ui://markcut/submit.html", ui: { visibility: ["app"] } } },
          { name: "output", description: "Output", inputSchema: { type: "object", properties: {} }, _meta: { "openai/outputTemplate": "ui://markcut/output.html" } }
        ] : []);
        const result = text => ({ content: [{ type: "text", text }] });
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        rl.on("line", line => {
          const message = JSON.parse(line);
          if (message.id == null) return;
          let value = {};
          if (message.method === "initialize") value = { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "fake", version: "1" } };
          if (message.method === "tools/list") value = { tools };
          if (message.method === "resources/list") value = { resources: includeUIMetadata ? [{ uri: "ui://markcut/preview.html", name: "Preview" }] : [] };
          if (message.method === "tools/call") {
            const { name, arguments: args = {} } = message.params;
            if (name === "fs" && args.command === "read") value = result(fs.readFileSync(args.args.path, "utf8"));
            if (name === "shell" && args.command === "exec") {
              const run = spawnSync("/bin/zsh", ["-lc", args.args.command], { encoding: "utf8" });
              value = result(JSON.stringify({ stdout: run.stdout, stderr: run.stderr, exit_code: run.status }));
            }
            if (name === "apply_patch") {
              const run = spawnSync("git", ["apply", "--recount", "--whitespace=nowarn", "-"], {
                cwd: args.cwd, input: args.patch, encoding: "utf8"
              });
              if (run.status !== 0) throw new Error(run.stderr);
              value = result(JSON.stringify({ exit_code: 0 }));
            }
            if (name === "preview") value = result("preview-called");
            if (name === "markcut.preview.submit") value = result("submit-called");
          }
          process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: value }) + "\n");
        });
        """#
        var rendered = source.replacingOccurrences(of: "__REQUIRE_CORE_AUTH__", with: requireCoreAuthorization ? "true" : "false")
        rendered = rendered.replacingOccurrences(of: "__INCLUDE_UI_METADATA__", with: includeUIMetadata ? "true" : "false")
        try Data(rendered.utf8).write(to: server)
        return Fixture(root: root, node: try nodePath(), server: server)
    }

    private static func nodePath() throws -> String {
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw XCTSkip("Node.js is required for NeoY bundled-runtime tests")
    }

    private static func stdioURL(node: String, script: String) -> String {
        var components = URLComponents()
        components.scheme = "stdio"
        components.path = node
        components.queryItems = [URLQueryItem(name: "arg", value: script)]
        return components.string!
    }

    private static func text(_ encoded: String) throws -> String {
        let prefix = "mcpresult:"
        let data = try XCTUnwrap(Data(base64Encoded: String(encoded.dropFirst(prefix.count))))
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    private static func waitForPID(_ client: NeoYMCPStdioClient) async throws -> Int32 {
        for _ in 0..<100 {
            if let pid = await client.processIdentifier() { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("stdio provider did not recover")
        throw CocoaError(.coderReadCorrupt)
    }

    @MainActor
    private static func waitForPID(_ federation: NeoYMCPFederation, name: String, unlike oldPID: Int32) async throws -> Int32 {
        for _ in 0..<100 {
            if let pid = await federation.stdioProcessIdentifier(name), pid != oldPID { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("federated stdio provider did not recover")
        throw CocoaError(.coderReadCorrupt)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
