import XCTest
@testable import NeoY

final class NeoCLISetupTests: XCTestCase {
    func testSetupAgentURLUsesAbsoluteBootstrapWithoutEmbeddingContents() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup \(UUID().uuidString).md")
        try "private test instructions".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let target = try NeoYAgentSetupLauncher.url(bootstrap: file, project: "neo/family-tutor")
        XCTAssertEqual(target.scheme, "https")
        XCTAssertEqual(target.host, "chatgpt.com")
        let prompt = try XCTUnwrap(URLComponents(url: target, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "prompt" })?.value)
        XCTAssertTrue(prompt.contains(file.path))
        XCTAssertTrue(prompt.contains("@neo"))
        XCTAssertFalse(prompt.contains("private test instructions"))
        XCTAssertThrowsError(try NeoYAgentSetupLauncher.url(
            bootstrap: URL(fileURLWithPath: "/nonexistent/neo-setup.md"), project: "neo/test"))
    }

    func testStartupPreferencesPreserveExplicitToolkitChoice() {
        let suite = "NeoCLISetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: NeoCLISetup.toolkitPreferenceKey)
        XCTAssertFalse(NeoCLISetup.wantsProjectsToolkit(defaults: defaults))
        defaults.set(true, forKey: NeoCLISetup.toolkitPreferenceKey)
        XCTAssertTrue(NeoCLISetup.wantsProjectsToolkit(defaults: defaults))
    }

    func testWorkspaceConfigurationDefaultsAndDerivesNeoRoot() {
        let root = NeoWorkspaceConfiguration.defaultWorkspaceRoot.path
        XCTAssertEqual(NeoWorkspaceConfiguration(schemaVersion: 1, workspaceRoot: root).neoRoot,
                       URL(fileURLWithPath: root).appendingPathComponent("neo").path)
    }

    func testWorkspaceConfigurationValidatesAndAtomicallyReadsBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config/workspace.json")

        XCTAssertThrowsError(try NeoWorkspaceConfiguration.validate(workspace.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try NeoWorkspaceConfiguration.validate("relative/path"))
        let saved = try NeoWorkspaceConfiguration.save(workspaceRoot: workspace.path, to: file)
        XCTAssertEqual(saved.workspaceRoot, workspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(try NeoWorkspaceConfiguration.load(from: file), saved)
        let originalData = try Data(contentsOf: file)
        XCTAssertThrowsError(try NeoWorkspaceConfiguration.save(workspaceRoot: "relative", to: file))
        XCTAssertEqual(try Data(contentsOf: file), originalData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOnlyExplicitlySelectedOptionalSkillsAreRestored() {
        let suite = "NeoCLISetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NeoCLISetup.desiredOptionalSkills(defaults: defaults).isEmpty)
        NeoCLISetup.setOptionalSkillDesired("markcut", enabled: true, defaults: defaults)
        NeoCLISetup.setOptionalSkillDesired("unknown", enabled: true, defaults: defaults)
        XCTAssertEqual(NeoCLISetup.desiredOptionalSkills(defaults: defaults), ["markcut"])
        NeoCLISetup.setOptionalSkillDesired("markcut", enabled: false, defaults: defaults)
        XCTAssertTrue(NeoCLISetup.desiredOptionalSkills(defaults: defaults).isEmpty)
    }

    func testExistingOptionalSkillsMigrateOnlyOnce() {
        let suite = "NeoCLISetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        NeoCLISetup.migrateOptionalSkillPreferencesIfNeeded(
            installed: ["markcut", "webhelm", "wechat-bro"], defaults: defaults)
        XCTAssertEqual(NeoCLISetup.desiredOptionalSkills(defaults: defaults),
                       ["markcut", "wechat-bro"])
        NeoCLISetup.setOptionalSkillDesired("markcut", enabled: false, defaults: defaults)
        NeoCLISetup.migrateOptionalSkillPreferencesIfNeeded(
            installed: ["markcut", "wechat-bro"], defaults: defaults)
        XCTAssertEqual(NeoCLISetup.desiredOptionalSkills(defaults: defaults), ["wechat-bro"])
    }

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
        XCTAssertEqual(NeoCLISetup.globalSkills(), ["events-bus", "daemon-service-manage", "webhelm", "agents-relay"])
    }

    func testMarkcutPreviewRequiresInstalledMarkcutSkill() {
        XCTAssertEqual(NeoCLISetup.missingSkills(forTool: "markcut_preview", installed: []),
                       ["markcut"])
        XCTAssertTrue(NeoCLISetup.missingSkills(
            forTool: "markcut.preview", installed: ["markcut"]).isEmpty)
        XCTAssertTrue(NeoCLISetup.missingSkills(
            forTool: "unrelated_tool", installed: []).isEmpty)
    }

    func testOptionalSkillCatalogDoesNotIncludeCoreDependencies() {
        XCTAssertEqual(Set(NeoCLISetup.optionalSkillSources.keys),
                       Set(["wechat-bro", "markcut"]))
        XCTAssertTrue(Set(NeoCLISetup.optionalSkillSources.keys)
            .isDisjoint(with: NeoCLISetup.requiredGlobalSkills))
        XCTAssertThrowsError(try NeoCLISetup.removeOptionalSkill("agents-relay"))
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
