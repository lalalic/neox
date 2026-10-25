import XCTest
@testable import NeoY

final class ManagedCoreRuntimeTests: XCTestCase {
    private func fixture(_ version: String, under parent: URL) throws -> URL {
        let source = parent.appendingPathComponent("candidate-\(version)")
        let tools = source.appendingPathComponent("src/core/tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data("{\"name\":\"@lalalic/neoy-core\",\"version\":\"\(version)\"}".utf8).write(to: source.appendingPathComponent("package.json"))
        try Data("export const healthy = true;".utf8).write(to: tools.appendingPathComponent("index.mjs"))
        return source
    }
    func testBootstrapUpgradeAndRollbackKeepIndependentVersions() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let v1 = try fixture("1.0.0", under: base)
        try NeoYManagedCoreRuntime.bootstrapIfMissing(bundle: v1, root: root)
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: root)?.lastPathComponent, "1.0.0")
        let v2 = try fixture("1.0.1", under: base)
        let node = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        try NeoYManagedCoreRuntime.upgrade(source: v2, version: "1.0.1", root: root, node: node)
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: root)?.lastPathComponent, "1.0.1")
        try NeoYManagedCoreRuntime.rollback(to: "1.0.0", root: root)
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: root)?.lastPathComponent, "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("versions/1.0.1/package.json").path))
    }
    func testStartupRecoversMissingActiveFilesAndPreservesDamagedCopy() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let seed = try fixture("1.0.0", under: base)
        try NeoYManagedCoreRuntime.bootstrapIfMissing(bundle: seed, root: root)
        let active = try XCTUnwrap(NeoYManagedCoreRuntime.active(in: root))
        try FileManager.default.removeItem(at: active.appendingPathComponent("src/core/tools/index.mjs"))
        XCTAssertNil(NeoYManagedCoreRuntime.active(in: root))
        try NeoYManagedCoreRuntime.bootstrapIfMissing(bundle: seed, root: root)
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: root)?.lastPathComponent, "1.0.0")
        let versions = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("versions"),
                                                                      includingPropertiesForKeys: nil)
        XCTAssertTrue(versions.contains { $0.lastPathComponent.hasPrefix(".damaged-1.0.0-") })
    }

    func testHealthyManagedRuntimeIsNotDowngradedOnStartup() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let seed = try fixture("1.0.0", under: base)
        let newer = try fixture("1.0.1", under: base)
        try NeoYManagedCoreRuntime.install(source: newer, version: "1.0.1", root: root)
        try NeoYManagedCoreRuntime.bootstrapIfMissing(bundle: seed, root: root)
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: root)?.lastPathComponent, "1.0.1")
    }

    func testStartupReturnsToHealthyPreviousCoreOnProbeFailure() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let seed = try fixture("1.0.0", under: base)
        let newer = try fixture("1.0.1", under: base)
        try NeoYManagedCoreRuntime.install(source: seed, version: "1.0.0", root: root)
        try NeoYManagedCoreRuntime.install(source: newer, version: "1.0.1", root: root)
        try "1.0.0".write(to: root.appendingPathComponent("previous-version"), atomically: true, encoding: .utf8)
        let selected = try NeoYManagedCoreRuntime.reconcileStartup(bundle: seed, root: root) {
            $0.lastPathComponent == "1.0.0"
        }
        XCTAssertEqual(selected, "1.0.0")
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: root)?.lastPathComponent, "1.0.0")
        XCTAssertTrue(NeoYManagedCoreRuntime.valid(root.appendingPathComponent("versions/1.0.1")))
    }

    func testStartupQuarantinesCoreThatFailsActualProbe() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let seed = try fixture("1.0.0", under: base)
        try NeoYManagedCoreRuntime.bootstrapIfMissing(bundle: seed, root: root)
        let current = try XCTUnwrap(NeoYManagedCoreRuntime.active(in: root))
        try Data("broken JavaScript".utf8).write(to: current.appendingPathComponent("src/core/tools/index.mjs"))
        let healthy: (URL) -> Bool = {
            (try? String(contentsOf: $0.appendingPathComponent("src/core/tools/index.mjs"),
                         encoding: .utf8))?.contains("healthy = true") == true
        }
        XCTAssertEqual(try NeoYManagedCoreRuntime.reconcileStartup(bundle: seed, root: root, probe: healthy), "1.0.0")
        XCTAssertTrue(healthy(try XCTUnwrap(NeoYManagedCoreRuntime.active(in: root))))
        let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("versions"),
                                                                    includingPropertiesForKeys: nil)
        XCTAssertTrue(entries.contains { $0.lastPathComponent.hasPrefix(".damaged-1.0.0-") })
    }

    func testOlderRegistryReleaseIsDetected() {
        XCTAssertTrue(NeoYManagedCoreRuntime.isOlder("0.1.1", than: "0.1.7"))
        XCTAssertFalse(NeoYManagedCoreRuntime.isOlder("0.1.8", than: "0.1.7"))
        XCTAssertFalse(NeoYManagedCoreRuntime.isOlder("0.1.7", than: "0.1.7"))
    }
    func testAutomaticCoreUpdateOnlyAcceptsNewerStableVersions() {
        XCTAssertTrue(NeoYManagedCoreRuntime.needsUpdate(installed: "0.1.9", latest: "0.1.10"))
        XCTAssertTrue(NeoYManagedCoreRuntime.needsUpdate(installed: nil, latest: "0.1.10"))
        XCTAssertFalse(NeoYManagedCoreRuntime.needsUpdate(installed: "0.1.10", latest: "0.1.10"))
        XCTAssertFalse(NeoYManagedCoreRuntime.needsUpdate(installed: "0.2.0", latest: "0.1.10"))
        XCTAssertFalse(NeoYManagedCoreRuntime.needsUpdate(installed: "0.1.9", latest: "latest"))
    }
    func testRollbackPreviousIsReversible() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let v1 = try fixture("1.0.0", under: base)
        let v2 = try fixture("1.0.1", under: base)
        try NeoYManagedCoreRuntime.install(source: v1, version: "1.0.0", root: root)
        try NeoYManagedCoreRuntime.install(source: v2, version: "1.0.1", root: root)
        try "1.0.0".write(to: root.appendingPathComponent("previous-version"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try NeoYManagedCoreRuntime.rollbackPrevious(root: root), "1.0.0")
        XCTAssertEqual(try NeoYManagedCoreRuntime.rollbackPrevious(root: root), "1.0.1")
    }
    func testStandaloneCorePackageUpgradeWithRealMCPProbe() throws {
        let bundleRoot = NeoYBundledRuntime.packagedRuntimeURL
        guard NeoYManagedCoreRuntime.valid(bundleRoot) else { return XCTFail("Bundled Core unavailable") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let npm = URL(fileURLWithPath: "/opt/homebrew/bin/npm")
        let pack = Process()
        pack.executableURL = npm
        pack.environment = ProcessInfo.processInfo.environment.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]) { _, configured in configured }
        pack.arguments = ["pack", bundleRoot.path, "--ignore-scripts", "--pack-destination", base.path]
        let pipe = Pipe()
        pack.standardOutput = pipe
        pack.standardError = pipe
        try pack.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        pack.waitUntilExit()
        guard pack.terminationStatus == 0 else { return XCTFail("npm pack failed with exit \(pack.terminationStatus)") }
        let archives = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tgz" }
        guard archives.count == 1 else { return XCTFail("expected one Core archive") }
        let managed = base.appendingPathComponent("managed")
        let packageData = try Data(contentsOf: bundleRoot.appendingPathComponent("package.json"))
        let packageInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: packageData) as? [String: Any])
        let expectedVersion = try XCTUnwrap(packageInfo["version"] as? String)
        XCTAssertEqual(try NeoYManagedCoreRuntime.registryUpgrade(version: archives[0].path, root: managed), expectedVersion)
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: managed)?.lastPathComponent, expectedVersion)
        XCTAssertFalse(NeoYManagedCoreRuntime.selected(bundle: bundleRoot, root: managed).path.contains("Contents/Resources/Runtime"))
    }

    func testInvalidCandidateNeverReplacesActiveRuntime() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        try NeoYManagedCoreRuntime.install(source: fixture("1.0.0", under: base), version: "1.0.0", root: root)
        XCTAssertThrowsError(try NeoYManagedCoreRuntime.install(source: base, version: "../bad", root: root))
        XCTAssertEqual(NeoYManagedCoreRuntime.active(in: root)?.lastPathComponent, "1.0.0")
    }
}
