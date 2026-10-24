import XCTest
@testable import NeoY

final class NeoCLISetupTests: XCTestCase {
    func testPublishedNeoCLIDistributionIdentity() {
        XCTAssertEqual(NeoCLISetup.npmCLI, "@lalalic/neo@1.0.2")
    }

    func testCLIInstalledPackageIdentity() {
        XCTAssertEqual(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.2"], executableExists: true), "ready")
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.1"], executableExists: true).hasPrefix("upgrade_required:"))
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.2"], executableExists: false).hasPrefix("upgrade_required:"))
    }

    func testLegacyNeoNeverSilentlyReplaced() {
        let result = NeoCLISetup.packageDecision(installed: ["neo": "1.0.2-p0.1"], executableExists: true)
        XCTAssertTrue(result.hasPrefix("migration_required:"))
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["neo": "1.0.2-p0.1", "@lalalic/neo": "1.0.2"], executableExists: true).hasPrefix("migration_required:"))
    }

    func testUnknownNeoNeverSilentlyReplaced() {
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: [:], executableExists: true).hasPrefix("ownership_unknown:"))
        XCTAssertEqual(NeoCLISetup.packageDecision(installed: [:], executableExists: false), "install")
    }

    func testNeoProjectsAreOnlyFirstLevelProducts() {
        let projects = [
            "neo/vlog", "neo/family-tutor", "neo/commerce",
            "neo/commerce/runs/2026-10-23/product",
            "neo/skills", "neo/skills/events-bus/evals",
            "browser-workspace/platforms/chatgpt", "ai-trading-lab",
            "neo/vlog"
        ].map { ["xchat_project": $0] }
        XCTAssertEqual(NeoCLISetup.neoProjectNames(from: projects),
                       ["commerce", "family-tutor", "vlog"])
    }

    func testLegacyCapabilityConfigurationDefaultsToolOverrides() throws {
        let oldConfiguration = #"{ "disabled": ["ask-questions"] }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NeoYCapabilityConfiguration.self, from: oldConfiguration)
        XCTAssertTrue(decoded.disabledTools.isEmpty)
        XCTAssertFalse(decoded.isEnabled(.askQuestions))

        var updated = decoded
        updated.disabledTools.insert("voice.session")
        let reloaded = try JSONDecoder().decode(NeoYCapabilityConfiguration.self,
                                                from: JSONEncoder().encode(updated))
        XCTAssertTrue(reloaded.disabledTools.contains("voice.session"))
    }

    func testNodeStoreCanAddRemoveWithoutChangingRemoteMachine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nodes.json")
        let store = NeoYNodeStore(file: file)
        let node = NeoYNodeConfiguration(name: "test-peer", url: "https://example.com/mcp",
                                         kind: .neoyPeer, token: "redacted")
        try await store.upsert(node)
        let afterAdd = await store.list()
        XCTAssertEqual(afterAdd.count, 1)
        try await store.remove("test-peer")
        let afterRemove = await store.list()
        XCTAssertTrue(afterRemove.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode([NeoYNodeConfiguration].self,
                                               from: Data(contentsOf: file)).isEmpty)
    }

    func testGlobalSkillsReadOnlyInventory() {
        XCTAssertEqual(NeoCLISetup.globalSkills(), ["events-bus", "daemon-service-manage", "webhelm"])
    }

    func testOptionalSkillCatalogDoesNotIncludeCoreDependencies() {
        XCTAssertEqual(Set(NeoCLISetup.optionalSkillSources.keys),
                       Set(["wechat-bro", "markcut", "agents-relay"]))
        XCTAssertTrue(Set(NeoCLISetup.optionalSkillSources.keys)
            .isDisjoint(with: NeoCLISetup.requiredGlobalSkills))
    }

    func testOptionalMCPToolsAreBackedByRealCapabilityState() throws {
        XCTAssertEqual(Set(NeoYRemoteToolCatalog.nativeOptionalTools.keys),
                       Set(["computer", "demo", "tour", "phone", "ask_questions"]))
        let capability = try XCTUnwrap(NeoYRemoteToolCatalog.nativeOptionalTools["computer"])
        var config = NeoYCapabilityConfiguration()
        XCTAssertTrue(config.isEnabled(capability))
        config.set(capability, enabled: false)
        XCTAssertFalse(config.isEnabled(capability))
        config.set(capability, enabled: true)
        XCTAssertTrue(config.isEnabled(capability))
    }

    func testCoreSkillsCannotBeRemovedAsOptional() {
        XCTAssertThrowsError(try NeoCLISetup.removeOptionalSkill("webhelm"))
    }

    func testDeveloperNeoSymlinkIsNeverTreatedAsManagedPackage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("neo")
        try FileManager.default.createSymbolicLink(
            at: executable, withDestinationURL: directory.appendingPathComponent("Workspace/neo/bin/neo"))
        XCTAssertTrue(NeoCLISetup.isDevelopmentLink(executable))

        let unrelated = directory.appendingPathComponent("other-neo")
        try FileManager.default.createSymbolicLink(
            at: unrelated, withDestinationURL: directory.appendingPathComponent("external/bin/neo"))
        XCTAssertFalse(NeoCLISetup.isDevelopmentLink(unrelated))
    }
}
