import XCTest

@testable import NeoY

final class ToolCallAuditTests: XCTestCase {
    func testMCPGETWithoutEventStreamAdvertisesAllowedMethods() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-mcp-405-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = ToolCallAudit(url: root.appendingPathComponent("audit.jsonl"))
        let (server, boundPort) = try await MainActor.run { try Self.makeServer(audit: audit) }
        defer { Task { @MainActor in server.stop() } }
        let url = URL(string: "http://127.0.0.1:\(boundPort)/mcp")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        // A client may probe GET to discover whether SSE is supported.
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 405)
        let allowed = Set((http.value(forHTTPHeaderField: "Allow") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        XCTAssertTrue(allowed.isSuperset(of: ["POST", "DELETE", "OPTIONS"]))

        request.httpMethod = "OPTIONS"
        let (_, options) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((options as? HTTPURLResponse)?.statusCode, 204)
    }

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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-exit-code-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("tool-calls.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
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
        XCTAssertEqual(entries[1].status, .warning)
        XCTAssertNotNil(entries[1].output)
    }

    func testOnlyNonzeroShellAndTerminalExitsProduceWarnings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-warning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tool-calls.jsonl")
        let audit = ToolCallAudit(url: url)
        let provenance = ToolCallAudit.Provenance(origin: .local, provider: "core")
        let examples: [(String, Int, ToolCallAudit.Status)] = [
            ("shell", 0, .succeeded), ("shell", 2, .warning),
            ("terminal", 137, .warning), ("other.tool", 2, .succeeded)
        ]
        for (tool, code, _) in examples {
            audit.record(callID: UUID(), toolName: tool, provenance: provenance,
                         status: .succeeded, output: .object([
                            "structuredContent": .object(["exitCode": .int(code)]),
                            "isError": .bool(false)
                         ]))
        }
        audit.flush()
        let entries = try Self.loadAuditEntries(at: url)
        XCTAssertEqual(entries.count, examples.count)
        for (entry, example) in zip(entries, examples) {
            XCTAssertEqual(entry.tool, example.0)
            XCTAssertEqual(entry.exitCode, example.1)
            XCTAssertEqual(entry.status, example.2)
            XCTAssertEqual(entry.phase, "terminal")
        }
        XCTAssertTrue(entries.allSatisfy { $0.truncated == nil })
    }

    func testRotationRetainsOnlyBoundedPrivateArchivesAndValidJSONL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-rotate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tool-calls.jsonl")
        let audit = ToolCallAudit(url: url, maxFileBytes: 920,
                                  maxArchives: 3, maxArchiveAge: 7 * 24 * 3600)
        let provenance = ToolCallAudit.Provenance(origin: .local, provider: "core")
        let lastID = UUID()
        for i in 0..<45 {
            audit.record(callID: i == 44 ? lastID : UUID(), toolName: "shell",
                         provenance: provenance, status: .succeeded,
                         output: .object(["exitCode": .int(0),
                                          "stdout": .string(String(repeating: "x", count: 100))]))
        }
        audit.flush()
        let rotated = root.appendingPathComponent("audit-rotated")
        let archives = try FileManager.default.contentsOfDirectory(at: rotated,
                                                                    includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 3)
        XCTAssertEqual(try Self.fileMode(at: rotated), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var entries: [ToolCallAudit.Entry] = []
        for file in archives + [url] {
            XCTAssertLessThanOrEqual(try Self.fileSize(at: file), 920)
            XCTAssertEqual(try Self.fileMode(at: file), 0o600)
            entries += try Self.loadAuditEntries(at: file)
        }
        XCTAssertTrue(entries.contains(where: { $0.callID == lastID.uuidString }))
        XCTAssertTrue(entries.allSatisfy { $0.status == .succeeded })
        XCTAssertLessThan(entries.count, 45, "oldest rotations should be discarded")
    }

    func testRotationDeletesExpiredManagedLogsButPreservesManualArchives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-prune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tool-calls.jsonl")
        let rotated = root.appendingPathComponent("audit-rotated")
        let manual = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: rotated, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        let stale = rotated.appendingPathComponent("tool-calls-1000-OLD.jsonl")
        let unrelated = rotated.appendingPathComponent("some-other-tool.jsonl")
        let preserved = manual.appendingPathComponent("tool-calls.before-rust.jsonl")
        for file in [stale, unrelated, preserved] {
            try "old\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 86400)],
                                                  ofItemAtPath: file.path)
        }
        let audit = ToolCallAudit(url: url, maxFileBytes: 520,
                                  maxArchives: 2, maxArchiveAge: 7 * 86400)
        let provenance = ToolCallAudit.Provenance(origin: .local, provider: nil)
        for _ in 0..<10 {
            audit.record(callID: UUID(), toolName: "shell", provenance: provenance,
                         status: .succeeded, output: .object(["exitCode": .int(0)]))
        }
        audit.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
    }

    func testExpiredManagedArchivesPruneWithoutNewRollover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-aged-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("audit-rotated")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let stale = archive.appendingPathComponent("tool-calls-1000-old.jsonl")
        try "old\n".write(to: stale, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 86400)],
                                              ofItemAtPath: stale.path)
        let url = root.appendingPathComponent("tool-calls.jsonl")
        let audit = ToolCallAudit(url: url, maxFileBytes: 4096, maxArchives: 5, maxArchiveAge: 7 * 86400)
        audit.record(callID: UUID(), toolName: "setup", provenance: .init(origin: .local, provider: nil),
                     status: .succeeded, output: .string("ok"))
        audit.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(try Self.loadAuditEntries(at: url).count, 1)
    }

    func testOversizedSingleRecordIsMarkedTruncatedAndCannotExceedSizeCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-oversize-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tool-calls.jsonl")
        let audit = ToolCallAudit(url: url, maxFileBytes: 700, maxArchives: 2)
        audit.record(callID: UUID(), toolName: "shell",
                     provenance: .init(origin: .remote, provider: "core"),
                     status: .succeeded,
                     input: .object(["secret": .string(String(repeating: "s", count: 4000))]),
                     output: .object(["exitCode": .int(9),
                                      "stdout": .string(String(repeating: "y", count: 9000))]))
        audit.flush()
        let entries = try Self.loadAuditEntries(at: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .warning)
        XCTAssertEqual(entries[0].exitCode, 9)
        XCTAssertEqual(entries[0].truncated, true)
        XCTAssertNil(entries[0].input)
        XCTAssertNil(entries[0].output)
        XCTAssertLessThanOrEqual(try Self.fileSize(at: url), 700)
    }

    private static func loadAuditEntries(at url: URL) throws -> [ToolCallAudit.Entry] {
        let data = try String(contentsOf: url, encoding: .utf8)
        return try data.split(separator: "\n").map {
            try JSONDecoder().decode(ToolCallAudit.Entry.self, from: Data($0.utf8))
        }
    }

    private static func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }

    private static func fileMode(at url: URL) throws -> UInt {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.uintValue ?? 0
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
