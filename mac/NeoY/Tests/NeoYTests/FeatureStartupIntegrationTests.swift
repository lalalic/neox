import XCTest
@testable import NeoY

final class FeatureStartupIntegrationTests: XCTestCase {
    private func prepare(enabled: Bool) throws -> (NeoYFeatureManager, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let products = base.appendingPathComponent("products")
        let state = base.appendingPathComponent("features.json")
        let product = products.appendingPathComponent("family-tutor")
        let package = product.appendingPathComponent("runtime/node_modules/@lalalic/family-tutor")
        let instance = product.appendingPathComponent("instance")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        let manifest = """
        {"schemaVersion":1,"id":"family-tutor","name":"Family Tutor","description":"Test",
         "version":"1.0.0","runtime":{"type":"node","serviceScript":"service.mjs",
         "initScript":"init.mjs","doctorScript":"doctor.mjs","defaultInstance":"default"},
         "mcp":{"provider":"family-tutor","defaultHost":"127.0.0.1","defaultPort":9999},
         "setup":{"required":false,"bootstrap":"","manual":"","mode":"none"},"remote":{"default":false}}
        """
        try Data(manifest.utf8).write(to: package.appendingPathComponent("neo-feature.json"))
        try Data("process.exit(0)".utf8).write(to: package.appendingPathComponent("doctor.mjs"))
        let service = """
        import fs from 'node:fs';
        if (process.argv[2] === 'start') fs.writeFileSync(process.argv[3] + '/started', 'yes');
        """
        try Data(service.utf8).write(to: package.appendingPathComponent("service.mjs"))
        let record = NeoYFeatureRecord(id: "family-tutor", package: "@lalalic/family-tutor",
                                       version: "1.0.0", enabled: enabled,
                                       state: .ready, provider: "family-tutor",
                                       mcpURL: "http://127.0.0.1:9999/mcp", error: nil)
        try JSONEncoder().encode([record]).write(to: state)
        return (NeoYFeatureManager(root: products, stateURL: state), base, instance)
    }

    func testEnabledFeatureServiceIsRestoredOnStartup() async throws {
        let (manager, base, instance) = try prepare(enabled: true)
        defer { try? FileManager.default.removeItem(at: base) }
        await manager.reconcileEnabledOnStartup()
        let record = await manager.record(id: "family-tutor")
        XCTAssertEqual(record?.state, .ready)
        XCTAssertNil(record?.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.appendingPathComponent("started").path))
    }

    func testDisabledFeatureRemainsStopped() async throws {
        let (manager, base, instance) = try prepare(enabled: false)
        defer { try? FileManager.default.removeItem(at: base) }
        await manager.reconcileEnabledOnStartup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.appendingPathComponent("started").path))
    }
}
