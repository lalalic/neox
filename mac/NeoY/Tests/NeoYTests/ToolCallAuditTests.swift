import XCTest

@testable import NeoY

final class ToolCallAuditTests: XCTestCase {
    func testGatewayAuditPreservesRawInputOutputAndFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-tool-call-audit", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let logURL = root.appendingPathComponent("tool-calls.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audit = ToolCallAudit(url: logURL)
        let (server, boundPort) = try await MainActor.run { try Self.makeServer(audit: audit) }

        await MainActor.run {
            server.register(name: "audit.success", description: "success") { _ in "ok" }
            server.register(name: "audit.delay", description: "delayed success") { _ async throws -> String in
                try await Task.sleep(for: .milliseconds(50))
                return "delayed-ok"
            }
            server.register(name: "audit.failure", description: "failure") { _ in
                throw NeoYRuntimeControlError.federation("TOKEN=audit-secret PATH=/private/tmp/audit-secret")
            }
            server.registerFederatedTool(
                descriptor: .object([
                    "name": .string("markcut.preview.success"),
                    "description": .string("forwarded success"),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:])])
                ]),
                name: "markcut.preview.success",
                provider: "markcut"
            ) { _ in
                let forwarded: [String: Any] = [
                    "content": [["type": "text", "text": "forwarded success"]],
                    "isError": false
                ]
                let data = try JSONSerialization.data(withJSONObject: forwarded)
                return "mcpresult:" + Data(data).base64EncodedString()
            }
            server.registerFederatedTool(
                descriptor: .object([
                    "name": .string("markcut.preview.is-error"),
                    "description": .string("forwarded error"),
                    "inputSchema": .object(["type": .string("object"), "properties": .object([:])])
                ]),
                name: "markcut.preview.is-error",
                provider: "markcut"
            ) { _ in
                let forwarded: [String: Any] = [
                    "content": [["type": "text", "text": "forwarded failure"]],
                    "isError": true
                ]
                let data = try JSONSerialization.data(withJSONObject: forwarded)
                return "mcpresult:" + Data(data).base64EncodedString()
            }
        }

        try await MainActor.run { try server.start() }
        defer { Task { @MainActor in server.stop() } }

        func call(_ payload: [String: Any]) async throws {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(boundPort)/mcp")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }

        let arguments = ["arguments": ["secret": "super-secret", "path": "/private/tmp/leak"]]
        try await call(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                        "params": ["name": "audit.success", "arguments": arguments]])
        try await call(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": ["name": "markcut.preview.is-error", "arguments": arguments]])
        try await call(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                        "params": ["name": "audit.failure", "arguments": arguments]])
        try await call(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "missing"]])
        try await call(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": [:]])
        try await call(["jsonrpc": "2.0", "id": 6, "method": "tools/call",
                        "params": ["name": "markcut.preview.success", "arguments": arguments]])

        async let first: Void = call(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                      "params": ["name": "audit.delay", "arguments": ["delay": true]]])
        async let second: Void = call(["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                                       "params": ["name": "audit.delay", "arguments": ["other": true]]])
        _ = try await (first, second)

        await MainActor.run { server.toolCallAudit.flush() }
        let serialized = try String(contentsOf: logURL, encoding: .utf8)
        let entries = try serialized.split(separator: "\n").map { line throws -> ToolCallAudit.Entry in
            let data = try XCTUnwrap(String(line).data(using: .utf8))
            return try JSONDecoder().decode(ToolCallAudit.Entry.self, from: data)
        }

        XCTAssertEqual(entries.count, 14)
        XCTAssertEqual(Set(entries.map(\.status)), [
            .started, .succeeded, .failed, .denied, .notFound
        ])
        XCTAssertTrue(entries.allSatisfy { !$0.callID.isEmpty })
        XCTAssertTrue(entries.allSatisfy { entry in
            entry.phase == (entry.status == .started ? "started" : "terminal")
        })
        XCTAssertTrue(entries.filter { $0.status != .started }.allSatisfy { $0.durationMS != nil })
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? UInt, 0o700)
        XCTAssertEqual(fileAttributes[.posixPermissions] as? UInt, 0o600)

        let nativeID = try XCTUnwrap(entries.last(where: { $0.tool == "audit.success" })?.callID)
        let nativeRecords = entries.filter { $0.callID == nativeID }
        XCTAssertEqual(nativeRecords.map(\.status), [.started, .succeeded])
        XCTAssertEqual(nativeRecords.map(\.provenance.origin), [.local, .local])

        let federatedID = try XCTUnwrap(entries.last(where: {
            $0.tool == "markcut.preview.is-error" && $0.status == .started
        })?.callID)
        let federatedRecords = entries.filter { $0.callID == federatedID }
        XCTAssertEqual(federatedRecords.map(\.status), [.started, .failed])
        XCTAssertEqual(federatedRecords.map(\.provenance.provider), ["markcut", "markcut"])

        let federatedSuccessID = try XCTUnwrap(entries.last(where: {
            $0.tool == "markcut.preview.success" && $0.status == .started
        })?.callID)
        let federatedSuccessRecords = entries.filter { $0.callID == federatedSuccessID }
        XCTAssertEqual(federatedSuccessRecords.map(\.status), [.started, .succeeded])
        XCTAssertEqual(federatedSuccessRecords.map(\.provenance.provider), ["markcut", "markcut"])

        XCTAssertTrue(entries.contains { $0.status == .denied && $0.error?.code == .invalidRequest })
        XCTAssertTrue(entries.contains { $0.status == .notFound && $0.error?.code == .unknownTool })
        XCTAssertTrue(entries.contains { $0.status == .failed && $0.error?.code == .handlerError })
        XCTAssertTrue(entries.contains { $0.status == .failed && $0.error?.code == .forwardedToolError })
        XCTAssertTrue(serialized.contains("super-secret"))
        XCTAssertTrue(serialized.contains("audit-secret"))
        let handlerFailure = try XCTUnwrap(entries.first(where: {
            $0.tool == "audit.failure" && $0.status == .failed
        }))
        XCTAssertNotNil(handlerFailure.error?.type)
        XCTAssertNotNil(handlerFailure.error?.domain)
        XCTAssertNotNil(handlerFailure.error?.number)
        XCTAssertTrue(handlerFailure.error?.message?.contains("audit-secret") == true)
        XCTAssertTrue(entries.contains { $0.status == .started && $0.input != nil })
        let forwardedFailure = try XCTUnwrap(entries.first(where: {
            $0.tool == "markcut.preview.is-error" && $0.status == .failed
        }))
        XCTAssertNotNil(forwardedFailure.output)
        XCTAssertTrue(serialized.contains("forwarded failure"))
        XCTAssertTrue(serialized.contains("audit-secret"))
        XCTAssertTrue(serialized.contains("forwarded failure"))
    }

    func testShellExitCodeFromRawFederatedOutput() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-exit-code-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let audit = ToolCallAudit(url: url)
        let callID = UUID()
        let provenance = ToolCallAudit.Provenance(origin: .remote, provider: "shell")
        audit.record(callID: callID, toolName: "shell", provenance: provenance,
                     status: .started, input: .object(["command": .string("false")]))
        audit.record(callID: callID, toolName: "shell", provenance: provenance,
                     status: .succeeded,
                     output: .object(["content": .array([
                         .object(["type": .string("text"),
                                  "text": .string("{\"exitCode\":7,\"stderr\":\"failure\"}")])
                     ])]))
        audit.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let entries = try lines.map { try JSONDecoder().decode(ToolCallAudit.Entry.self, from: Data($0.utf8)) }
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].input, .object(["command": .string("false")]))
        XCTAssertEqual(entries[1].exitCode, 7)
        XCTAssertNotNil(entries[1].output)
    }

    @MainActor
    private static func makeServer(audit: ToolCallAudit) throws -> (MCPServer, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 30000...60000)
            let server = MCPServer(name: "audit-test", port: port, toolCallAudit: audit)
            do {
                try server.start()
                return (server, port)
            } catch {
                server.stop()
            }
        }
        throw CocoaError(.executableLoad)
    }
}
