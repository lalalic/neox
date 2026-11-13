import XCTest
@testable import NeoY

final class ManagedRustCoreRuntimeTests: XCTestCase {
    private func fixture(_ version: String, in parent: URL) throws -> URL {
        let binary = parent.appendingPathComponent("core-\(version)")
        try "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf '%s\\n' '\(version)'; exit 0; fi\nexit 2\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rust-core-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testFreshInstallUsesVersionedRustExecutableWithoutNode() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let source = try fixture("1.0.0", in: base)
        XCTAssertEqual(NeoYManagedRustCoreRuntime.version(of: source), "1.0.0")
        try NeoYManagedRustCoreRuntime.bootstrapIfMissing(bundle: source, root: root, probe: { _ in true })
        let installed = try XCTUnwrap(NeoYManagedRustCoreRuntime.active(in: root))
        XCTAssertEqual(installed.deletingLastPathComponent().lastPathComponent, "1.0.0")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(NeoYBundledRuntime.coreMCPServers(binary: installed).map(\.name), ["core"])
        XCTAssertTrue(NeoYBundledRuntime.coreMCPServers(binary: nil).isEmpty)
    }
    func testHealthyCoreSurvivesRestartWithoutDowngrade() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let older = try fixture("1.0.0", in: base)
        let newer = try fixture("1.0.1", in: base)
        try NeoYManagedRustCoreRuntime.install(source: newer, version: "1.0.1", root: root)
        XCTAssertEqual(try NeoYManagedRustCoreRuntime.reconcileStartup(bundle: older, root: root,
                                probe: { _ in true }), "1.0.1")
        XCTAssertEqual(NeoYManagedRustCoreRuntime.active(in: root)?.deletingLastPathComponent().lastPathComponent, "1.0.1")
    }
    func testSignedBundleUpgradeAndPreviousRollback() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let old = try fixture("1.0.0", in: base), newer = try fixture("1.0.1", in: base)
        try NeoYManagedRustCoreRuntime.install(source: old, version: "1.0.0", root: root)
        XCTAssertEqual(try NeoYManagedRustCoreRuntime.reconcileStartup(bundle: newer, root: root,
                                probe: { _ in true }), "1.0.1")
        XCTAssertEqual(try NeoYManagedRustCoreRuntime.rollbackPrevious(root: root, probe: { _ in true }), "1.0.0")
        XCTAssertEqual(try NeoYManagedRustCoreRuntime.rollbackPrevious(root: root, probe: { _ in true }), "1.0.1")
    }
    func testCorruptInstalledExecutableQuarantinedAndRecoveredFromSeed() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let seed = try fixture("1.0.0", in: base)
        try NeoYManagedRustCoreRuntime.bootstrapIfMissing(bundle: seed, root: root, probe: { _ in true })
        let installed = try XCTUnwrap(NeoYManagedRustCoreRuntime.active(in: root))
        try FileManager.default.removeItem(at: installed)
        XCTAssertNil(NeoYManagedRustCoreRuntime.active(in: root))
        XCTAssertEqual(try NeoYManagedRustCoreRuntime.reconcileStartup(bundle: seed, root: root,
                                probe: { _ in true }), "1.0.0")
        let dirs = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("versions").path)
        XCTAssertTrue(dirs.contains(where: { $0.hasPrefix(".damaged-1.0.0-") }))
    }
    func testStartupProbeFailureReturnsToHealthyPreviousVersion() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let seed = try fixture("1.0.0", in: base), bad = try fixture("1.0.1", in: base)
        try NeoYManagedRustCoreRuntime.install(source: seed, version: "1.0.0", root: root)
        try NeoYManagedRustCoreRuntime.install(source: bad, version: "1.0.1", root: root)
        try "1.0.0".write(to: root.appendingPathComponent("previous-version"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try NeoYManagedRustCoreRuntime.reconcileStartup(bundle: seed, root: root,
                           probe: { !$0.path.contains("/1.0.1/") }), "1.0.0")
        XCTAssertEqual(NeoYManagedRustCoreRuntime.active(in: root)?.deletingLastPathComponent().lastPathComponent, "1.0.0")
    }
    func testFailedUpgradeDoesNotReplaceExistingCore() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let old = try fixture("1.0.0", in: base), next = try fixture("1.0.1", in: base)
        try NeoYManagedRustCoreRuntime.install(source: old, version: "1.0.0", root: root)
        XCTAssertThrowsError(try NeoYManagedRustCoreRuntime.upgrade(next.path, root: root,
                    probe: { _ in true }, signature: { _ in false }))
        XCTAssertThrowsError(try NeoYManagedRustCoreRuntime.upgrade(next.path, root: root,
                    probe: { _ in false }, signature: { _ in true }))
        XCTAssertEqual(NeoYManagedRustCoreRuntime.active(in: root)?.deletingLastPathComponent().lastPathComponent, "1.0.0")
    }
    func testImmutableVersionRejectsDifferentBinaryWithoutChangingActive() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("managed")
        let original = try fixture("1.0.0", in: base)
        try NeoYManagedRustCoreRuntime.install(source: original, version: "1.0.0", root: root)
        let other = base.appendingPathComponent("alternate")
        try "#!/bin/sh\nprintf '1.0.0\\n'\n".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: other.path)
        XCTAssertThrowsError(try NeoYManagedRustCoreRuntime.install(source: other, version: "1.0.0", root: root))
        XCTAssertEqual(NeoYManagedRustCoreRuntime.active(in: root)?.deletingLastPathComponent().lastPathComponent, "1.0.0")
    }
    func testVersionValidationAndRollbackPathInjection() throws {
        XCTAssertTrue(NeoYManagedRustCoreRuntime.isOlder("0.2.4", than: "0.3.0"))
        XCTAssertFalse(NeoYManagedRustCoreRuntime.isOlder("1.1.0", than: "1.0.5"))
        XCTAssertFalse(NeoYManagedRustCoreRuntime.validVersion("../bad"))
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertThrowsError(try NeoYManagedRustCoreRuntime.rollback(to: "../bad", root: base))
    }
    func testUnresponsiveVersionCandidateCannotBlockStartup() throws {
        let base = try directory(); defer { try? FileManager.default.removeItem(at: base) }
        let binary = base.appendingPathComponent("hung-rust-core")
        try "#!/bin/sh\nsleep 20\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let start = Date()
        XCTAssertNil(NeoYManagedRustCoreRuntime.version(of: binary))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }
    func testRealRustMCPInitializationAndToolListWithoutNode() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CoreRust/target/debug/neoy-core-rust")
        guard FileManager.default.isExecutableFile(atPath: source.path) else {
            throw XCTSkip("Build CoreRust with cargo test before this native integration test")
        }
        XCTAssertTrue(NeoYManagedRustCoreRuntime.probeMCP(source))
        XCTAssertNotNil(NeoYManagedRustCoreRuntime.version(of: source))
    }
}
