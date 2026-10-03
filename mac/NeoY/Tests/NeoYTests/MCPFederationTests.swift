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
        XCTAssertTrue(Set(snapshot.tools.map(\.name)).isSuperset(of: ["fs_read", "shell_exec", "apply_patch"]))

        let file = fixture.root.appendingPathComponent("sample.txt")
        try Data("before\n".utf8).write(to: file)
        let readResult = try await client.call(name: "fs_read", arguments: .object([
            "path": .string(file.path)
        ]))
        XCTAssertTrue(try Self.text(readResult).contains("before"))
        let shellResult = try await client.call(name: "shell_exec", arguments: .object([
            "command": .string("printf lifecycle-ok")
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
            XCTAssertTrue(Set(names).isSuperset(of: ["fs_read", "shell_exec", "apply_patch"]))
        }
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
        let recoveryResult = try await client.call(name: "shell_exec", arguments: .object([
            "command": .string("printf recovered")
        ]))
        XCTAssertTrue(try Self.text(recoveryResult).contains("recovered"))
    }

    private struct Fixture {
        let root: URL
        let node: String
        let server: URL
    }

    private static func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-stdio-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let server = root.appendingPathComponent("fake-mcp.mjs")
        let source = #"""
        import fs from "node:fs";
        import readline from "node:readline";
        import { spawnSync } from "node:child_process";
        if (process.env.NEO_CORE_FULL_ACCESS_ACK !== "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS") process.exit(78);
        if (process.env.FAKE_MCP_FAIL_FILE && fs.existsSync(process.env.FAKE_MCP_FAIL_FILE)) process.exit(70);
        const tools = ["fs_read", "shell_exec", "apply_patch"].map(name => ({
          name, description: name, inputSchema: { type: "object", properties: {} }
        }));
        const result = text => ({ content: [{ type: "text", text }] });
        const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
        rl.on("line", line => {
          const message = JSON.parse(line);
          if (message.id == null) return;
          let value = {};
          if (message.method === "initialize") value = { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "fake", version: "1" } };
          if (message.method === "tools/list") value = { tools };
          if (message.method === "resources/list") value = { resources: [] };
          if (message.method === "tools/call") {
            const { name, arguments: args = {} } = message.params;
            if (name === "fs_read") value = result(fs.readFileSync(args.path, "utf8"));
            if (name === "shell_exec") {
              const run = spawnSync("/bin/zsh", ["-lc", args.command], { encoding: "utf8" });
              value = result(JSON.stringify({ stdout: run.stdout, stderr: run.stderr, exit_code: run.status }));
            }
            if (name === "apply_patch") {
              const run = spawnSync("git", ["apply", "--recount", "--whitespace=nowarn", "-"], {
                cwd: args.cwd, input: args.patch, encoding: "utf8"
              });
              if (run.status !== 0) throw new Error(run.stderr);
              value = result(JSON.stringify({ exit_code: 0 }));
            }
          }
          process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: value }) + "\n");
        });
        """#
        try Data(source.utf8).write(to: server)
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
