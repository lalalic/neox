import XCTest
@testable import NeoY

final class NeoCLISetupTests: XCTestCase {
    func testXChatHTTPBootstrapUsesNeoCLIWithoutNewMCPTool() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xchat-bootstrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let working = root.appendingPathComponent("neo")
        try """
        #!/bin/sh
        test "$1" = "bootstrap" || exit 4
        printf '# XChat Harness Bootstrap\\nBootstrap works\\n'
        """.write(to: working, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: working.path)
        let reply = NeoYXChatBootstrapRoute.render(cli: working)
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.contentType, "text/markdown; charset=utf-8")
        XCTAssertTrue(String(data: try XCTUnwrap(reply.body), encoding: .utf8)?.contains("Bootstrap works") == true)

        let failed = root.appendingPathComponent("failed")
        try "#!/bin/sh\\necho wrong data\\n".write(to: failed, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failed.path)
        XCTAssertEqual(NeoYXChatBootstrapRoute.render(cli: failed).status, 503)
        XCTAssertEqual(NeoYXChatBootstrapRoute.render(cli: nil).status, 503)
    }

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

    func testNeoHarnessIsMandatoryRegardlessOfLegacyToolkitPreference() {
        let suite = "NeoCLISetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: NeoCLISetup.toolkitPreferenceKey)
        XCTAssertTrue(NeoCLISetup.wantsProjectsToolkit(defaults: defaults))
        defaults.set(true, forKey: NeoCLISetup.toolkitPreferenceKey)
        XCTAssertTrue(NeoCLISetup.wantsProjectsToolkit(defaults: defaults))
    }

    func testWorkspaceConfigurationDefaultsIndependentProjectRoot() {
        let root = NeoWorkspaceConfiguration.defaultNeoRoot.path
        XCTAssertEqual(NeoWorkspaceConfiguration(schemaVersion: 1, neoRoot: root).neoRoot, root)
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
        let saved = try NeoWorkspaceConfiguration.save(neoRoot: workspace.path, to: file)
        XCTAssertEqual(saved.neoRoot, workspace.resolvingSymlinksInPath().path)
        XCTAssertEqual(try NeoWorkspaceConfiguration.load(from: file), saved)
        let prepared = try NeoWorkspaceConfiguration.prepareIfNeeded(at: file)
        XCTAssertEqual(prepared, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.neoRoot))
        let customProjects = directory.appendingPathComponent("custom-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: customProjects, withIntermediateDirectories: true)
        let customized = try NeoWorkspaceConfiguration.save(neoRoot: customProjects.path, to: file)
        XCTAssertEqual(customized.neoRoot, customProjects.path)
        let originalData = try Data(contentsOf: file)
        XCTAssertThrowsError(try NeoWorkspaceConfiguration.save(neoRoot: "relative", to: file))
        XCTAssertEqual(try Data(contentsOf: file), originalData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFirstLaunchMigratesPreviousRootFieldsOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let selected = directory.appendingPathComponent("selected-projects", isDirectory: true)
        let file = directory.appendingPathComponent("config/workspace.json")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let historical: [String: Any] = ["schemaVersion": 1,
                                          "workspaceRoot": workspace.path,
                                          "projectsRoot": selected.path]
        try JSONSerialization.data(withJSONObject: historical).write(to: file)
        XCTAssertThrowsError(try NeoWorkspaceConfiguration.load(from: file))
        let migrated = try NeoWorkspaceConfiguration.prepareIfNeeded(at: file)
        XCTAssertEqual(migrated.neoRoot, selected.resolvingSymlinksInPath().path)
        let data = try Data(contentsOf: file)
        let savedFields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(savedFields.keys), ["schemaVersion", "neoRoot"])
        XCTAssertEqual(try NeoWorkspaceConfiguration.prepareIfNeeded(at: file), migrated)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testLegacyWorkspaceOnlyConfigPreservesFormerNeoSubfolder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let file = directory.appendingPathComponent("config/workspace.json")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "workspaceRoot": workspace.path])
            .write(to: file)
        let previouslyEffective = workspace.appendingPathComponent("neo", isDirectory: true)
        try FileManager.default.createDirectory(at: previouslyEffective, withIntermediateDirectories: true)
        let sentinel = previouslyEffective.appendingPathComponent("project-sentinel.txt")
        try "must remain untouched".write(to: sentinel, atomically: true, encoding: .utf8)
        XCTAssertEqual(try NeoWorkspaceConfiguration.prepareIfNeeded(at: file).neoRoot,
                       previouslyEffective.resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "must remain untouched")
        XCTAssertEqual(try NeoWorkspaceConfiguration.load(from: file).neoRoot,
                       previouslyEffective.resolvingSymlinksInPath().path)
    }

    func testRequiredServiceOwnershipAndRecoveryPlan() {
        let required = NeoRequiredSkillServices.owners(optionalEnabled: [])
        XCTAssertEqual(Set(required.map(\.name)), ["events-bus", "agents-relay"])
        let events = required.first { $0.name == "events-bus" }!
        XCTAssertEqual(events.services, ["nats", "history"])
        XCTAssertEqual(NeoRequiredSkillServices.missingServices(for: events, states: [
            "events-bus/nats": "online", "unrelated/daemon": "errored"
        ]), ["history"])
        XCTAssertEqual(NeoRequiredSkillServices.unhealthyServices(for: events, states: [
            "events-bus/nats": "online", "events-bus/history": "stopped"
        ]), ["history"])
        XCTAssertTrue(NeoRequiredSkillServices.unhealthyServices(for: events, states: [
            "events-bus/nats": "online", "events-bus/history": "online"
        ]).isEmpty)
    }

    func testVersionPinnedPublishedServiceRequiresLatestMigration() {
        func pm2(_ binary: String, _ args: [String]) -> [String: Any] {
            ["pm2_env": ["pm_exec_path": binary, "args": args]]
        }
        XCTAssertTrue(NeoRequiredSkillServices.usesPinnedPublishedPackage(
            pm2("/opt/homebrew/bin/npx", ["-y", "--package", "agents-relay@2.0.196", "agents-relayd"]),
            ownerName: "agents-relay"))
        XCTAssertFalse(NeoRequiredSkillServices.usesPinnedPublishedPackage(
            pm2("/opt/homebrew/bin/npx", ["-y", "--package", "agents-relay@latest", "agents-relayd"]),
            ownerName: "agents-relay"))
        XCTAssertTrue(NeoRequiredSkillServices.usesPinnedPublishedPackage(
            pm2("/opt/homebrew/bin/npx", ["-y", "wechat-bro@2.0.1", "--daemon"]),
            ownerName: "wechat-bro"))
        XCTAssertFalse(NeoRequiredSkillServices.usesPinnedPublishedPackage(
            pm2("/opt/homebrew/bin/npx", ["-y", "--package", "/local/vlog-0.1.1.tgz"]),
            ownerName: "agents-relay"))
        XCTAssertFalse(NeoRequiredSkillServices.usesPinnedPublishedPackage(
            pm2("/usr/bin/node", ["events-bus/api/server.mjs"]),
            ownerName: "events-bus"))
        XCTAssertEqual(NeoRequiredSkillServices.publicationWatcher, "neo/package-service-updater")
    }

    func testEventsBusRuntimeDependenciesAreValidatedWithoutSideEffects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(NeoRequiredSkillServices.eventsBusRuntimeReady(at: root))
        let dependency = root.appendingPathComponent("node_modules/@nats-io/transport-node")
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try "{}".write(to: dependency.appendingPathComponent("package.json"),
                       atomically: true, encoding: .utf8)
        XCTAssertTrue(NeoRequiredSkillServices.eventsBusRuntimeReady(at: root))
    }

    func testLegacyEventsHistoryMigrationOnlyAcceptsOwnedExecutable() {
        XCTAssertTrue(NeoRequiredSkillServices.isLegacyEventsHistory(
            "/Users/test/.agents/skills/events-bus/api/server.mjs"))
        XCTAssertFalse(NeoRequiredSkillServices.isLegacyEventsHistory(
            "/Users/test/another-service/api/server.mjs"))
        XCTAssertFalse(NeoRequiredSkillServices.isLegacyEventsHistory(nil))
    }

    func testOptionalServicesAreSupervisedOnlyWhenEnabled() {
        XCTAssertFalse(NeoRequiredSkillServices.owners(optionalEnabled: []).contains { $0.name == "wechat-bro" })
        XCTAssertTrue(NeoRequiredSkillServices.owners(optionalEnabled: ["wechat-bro"])
            .contains { $0.name == "wechat-bro" && $0.services == ["daemon", "orchestrator"] })
        XCTAssertFalse(NeoRequiredSkillServices.owners(optionalEnabled: ["markcut"])
            .contains { $0.name == "markcut" })
    }

    func testOnlyExplicitlySelectedOptionalSkillsAreRestored() {
        let suite = "NeoCLISetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NeoCLISetup.desiredOptionalSkills(defaults: defaults).isEmpty)
        NeoCLISetup.setOptionalSkillDesired("wechat-bro", enabled: true, defaults: defaults)
        NeoCLISetup.setOptionalSkillDesired("markcut", enabled: true, defaults: defaults)
        NeoCLISetup.setOptionalSkillDesired("unknown", enabled: true, defaults: defaults)
        XCTAssertEqual(NeoCLISetup.desiredOptionalSkills(defaults: defaults), ["wechat-bro"])
        NeoCLISetup.setOptionalSkillDesired("wechat-bro", enabled: false, defaults: defaults)
        XCTAssertTrue(NeoCLISetup.desiredOptionalSkills(defaults: defaults).isEmpty)
    }

    func testExistingOptionalSkillsMigrateOnlyOnce() {
        let suite = "NeoCLISetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        NeoCLISetup.migrateOptionalSkillPreferencesIfNeeded(
            installed: ["markcut", "webhelm", "wechat-bro"], defaults: defaults)
        XCTAssertEqual(NeoCLISetup.desiredOptionalSkills(defaults: defaults), ["wechat-bro"])
        // Ignore stale markcut preferences left by Neo.app 2.3.13.
        defaults.set(["markcut", "wechat-bro"], forKey: NeoCLISetup.optionalSkillsPreferenceKey)
        XCTAssertEqual(NeoCLISetup.desiredOptionalSkills(defaults: defaults), ["wechat-bro"])
        NeoCLISetup.migrateOptionalSkillPreferencesIfNeeded(
            installed: ["markcut", "wechat-bro"], defaults: defaults)
        XCTAssertEqual(NeoCLISetup.desiredOptionalSkills(defaults: defaults), ["wechat-bro"])
    }

    func testPublishedNeoCLIDistributionIdentity() {
        XCTAssertEqual(NeoCLISetup.npmCLI, "@lalalic/neo@1.0.3")
    }

    func testCLIInstalledPackageIdentity() {
        XCTAssertEqual(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.3"], executableExists: true), "ready")
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.2"], executableExists: true).hasPrefix("upgrade_required:"))
        XCTAssertTrue(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.3"], executableExists: false).hasPrefix("upgrade_required:"))
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
        let independent: [[String: Any]] = [
            ["xchat_project": "content-distribution", "neo_project": true],
            ["xchat_project": "vlog", "neo_project": true],
            ["xchat_project": "runs/temp", "neo_project": true],
        ]
        XCTAssertEqual(NeoCLISetup.neoProjectNames(from: projects + independent),
                       ["content-distribution", "vlog"])
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

    func testProjectsEnableSelectionIsPersistentAndNotServiceStatus() {
        let suite = "ProjectSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let projects = ["vlog", "family-tutor", "commerce"]
        XCTAssertEqual(NeoCLISetup.enabledProjects(discovered: projects, defaults: defaults), Set(projects))
        NeoCLISetup.setProjectEnabled("commerce", enabled: false, discovered: projects, defaults: defaults)
        XCTAssertEqual(NeoCLISetup.enabledProjects(discovered: projects, defaults: defaults),
                       ["vlog", "family-tutor"])
        NeoCLISetup.setProjectEnabled("commerce", enabled: true, discovered: projects, defaults: defaults)
        XCTAssertEqual(NeoCLISetup.enabledProjects(discovered: projects, defaults: defaults), Set(projects))
        NeoCLISetup.setProjectEnabled("nonexistent", enabled: false, discovered: projects, defaults: defaults)
        XCTAssertEqual(NeoCLISetup.enabledProjects(discovered: projects, defaults: defaults), Set(projects))
    }

    func testProjectPreferencesSurviveTemporaryDiscoveryFailure() {
        let suite = "ProjectSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        NeoCLISetup.setProjectEnabled("commerce", enabled: false,
                                      discovered: ["commerce", "vlog"], defaults: defaults)
        XCTAssertTrue(NeoCLISetup.enabledProjects(discovered: [], defaults: defaults).isEmpty)
        XCTAssertEqual(NeoCLISetup.enabledProjects(discovered: ["commerce", "vlog"], defaults: defaults), ["vlog"])
    }

    func testPreviewRequiresSkillOnDiskBeforeToolExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(NeoCLISetup.missingSkillsOnDisk(forTool: "markcut.preview", directory: directory), ["markcut"])
        XCTAssertEqual(NeoCLISetup.missingSkillsOnDisk(forTool: "markcut_preview", directory: directory), ["markcut"])
        let skill = directory.appendingPathComponent("markcut")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "skill".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(NeoCLISetup.missingSkillsOnDisk(forTool: "neo_markcut_preview", directory: directory).isEmpty)
        XCTAssertTrue(NeoCLISetup.missingSkillsOnDisk(forTool: "phone", directory: directory).isEmpty)
    }

    func testManagedNeoNewerVersionIsNotDowngraded() {
        XCTAssertEqual(NeoCLISetup.packageDecision(installed: ["@lalalic/neo": "1.0.3"], executableExists: true),
                       "ready")
    }

    func testNeoCLIUpdateIsIndependentOptIn() {
        let defaults = UserDefaults(suiteName: "ToolkitUpdate.\(UUID().uuidString)")!
        XCTAssertFalse(defaults.bool(forKey: NeoCLISetup.autoUpdateToolkitKey))
    }

    func testDynamicToolFeaturesKeepVersion211DiscoveryBehavior() {
        let list = NeoYRemoteToolCatalog.visibleFeatureTools(
            discovered: ["computer", "discord", "markcut.preview", "events", "shell"],
            disabled: ["voice.session"])
        XCTAssertEqual(list, ["computer", "discord", "voice.reply"])
        let refreshed = NeoYRemoteToolCatalog.visibleFeatureTools(
            discovered: ["computer", "new_provider_tool", "shell"], disabled: [])
        XCTAssertEqual(refreshed, ["computer", "new_provider_tool"])
        XCTAssertFalse(list.contains("new_provider_tool"))
    }

    func testToolDependenciesAndTransitiveRequirements() {
        XCTAssertEqual(NeoCLISetup.requiredSkills(forTool: "markcut.preview"), ["markcut"])
        XCTAssertEqual(NeoCLISetup.requiredSkills(forTool: "chatgpt"), ["webhelm", "daemon-service-manage"])
        XCTAssertEqual(NeoCLISetup.requiredSkills(forTool: "webhelm.navigate"), ["webhelm", "daemon-service-manage"])
        XCTAssertEqual(NeoCLISetup.requiredSkills(forTool: "phone"), [])
        XCTAssertEqual(NeoCLISetup.requiredSkills(forTool: "custom",
            advertised: ["wechat-bro"]), ["wechat-bro", "daemon-service-manage"])
    }

    func testToolMetadataRequiresApprovedSkillSources() {
        let descriptor: [String: Any] = [
            "name": "browser.test", "_meta": [
                "neo": ["requires": ["skills": ["webhelm"]]]
            ]
        ]
        XCTAssertEqual(NeoCLISetup.advertisedSkills(from: descriptor), ["webhelm"])
        XCTAssertEqual(NeoCLISetup.advertisedSkills(from: ["name": "other"]), [])
        XCTAssertThrowsError(try NeoCLISetup.ensureSkills(["unapproved-skill"]))
        XCTAssertEqual(NeoCLISetup.managedSkillSources["webhelm"], "lalalic/webhelm")
        XCTAssertEqual(NeoCLISetup.managedSkillSources["markcut"], "lalalic/markcut")
    }

    func testLegacySkillFolderDoesNotSatisfyWebhelmRequirement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("webhelm-skill-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("browser-workspace")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try "name: webhelm".write(to: legacy.appendingPathComponent("SKILL.md"),
                                atomically: true, encoding: .utf8)
        XCTAssertTrue(NeoCLISetup.missingSkillsOnDisk(forTool: "chatgpt", directory: root).contains("webhelm"))
        let current = root.appendingPathComponent("webhelm")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try "name: webhelm".write(to: current.appendingPathComponent("SKILL.md"),
                                atomically: true, encoding: .utf8)
        XCTAssertFalse(NeoCLISetup.missingSkillsOnDisk(forTool: "chatgpt", directory: root).contains("webhelm"))
    }

    func testWebhelmEnsureNeverCreatesSessionsWhenHealthyOrDeferred() throws {
        for response in [#"{"ok":true,"chrome_guard":{"status":"healthy"}}"#,
                         #"{"ok":true,"deferred_upgrade":true,"session_count":1}"#] {
            var calls: [[String]] = []
            try NeoCLISetup.setupWebhelm { args in
                calls.append(args)
                return response
            }
            XCTAssertEqual(calls, [["ensure"]], "Healthy or busy WebHelm must not be re-provisioned")
        }
    }

    func testWebhelmBootstrapUsesOnlyOwnedSetupAndEnsure() throws {
        var calls: [[String]] = []
        try NeoCLISetup.setupWebhelm { args in
            calls.append(args)
            if calls.count == 1 { throw NSError(domain: "test", code: 1) }
            return args == ["setup"] ? #"{"status":"ready"}"# : #"{"ok":true}"#
        }
        XCTAssertEqual(calls, [["ensure"], ["setup"], ["ensure"]])
        XCTAssertThrowsError(try NeoCLISetup.setupWebhelm { args in
            return args == ["setup"] ? #"{"status":"ready"}"# : "warning not JSON"
        })
    }

    func testCLICapturesDiagnosticsWithoutCorruptingJSON() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neoy-cli-stdout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("sample.sh")
        try """
        #!/bin/sh
        echo 'ExperimentalWarning: SQLite is experimental' >&2
        echo '{"ok":true}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: script.path)
        let result = try NeoCLISetup.runCLI(executable: script, arguments: [])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("ExperimentalWarning"))
        XCTAssertTrue(NeoCLISetup.webhelmEnsureSucceeded(result.stdout))
        XCTAssertFalse(NeoCLISetup.webhelmEnsureSucceeded(result.stderr + result.stdout))
    }

    func testWebhelmSetupDependsOnGlobalCLIWithoutFixedSkillInstallerPath() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/NeoY/NeoCLISetup.swift")
        let code = try String(contentsOf: sources, encoding: .utf8)
        XCTAssertTrue(code.contains("npx"))
        XCTAssertTrue(code.contains("--yes"))
        XCTAssertTrue(code.contains("webhelm@latest"))
        XCTAssertFalse(code.contains("webhelm/scripts/install-global-cli.sh"))
        XCTAssertFalse(code.contains("ensureGlobalWebhelmLauncher"))
        XCTAssertFalse(code.contains("installed.insert(\"webhelm\")"))
        XCTAssertFalse(code.contains("globalWebhelmCLI"))
    }

    func testWebhelmSetupHealthNeedsDaemonAndManagedChrome() {
        XCTAssertTrue(NeoCLISetup.webhelmIsHealthy(
            #"{"managed_chrome":{"pid":120}, "daemon":{"running":true}}"#))
        XCTAssertFalse(NeoCLISetup.webhelmIsHealthy(
            #"{"managed_chrome":null, "daemon":{"running":true}}"#))
        XCTAssertFalse(NeoCLISetup.webhelmIsHealthy(
            #"{"managed_chrome":{"pid":120}, "daemon":{"running":false}}"#))
        XCTAssertFalse(NeoCLISetup.webhelmIsHealthy("not JSON"))
    }

    func testAutomaticSkillUpdatePreservesUnownedAndDeveloperSources() {
        XCTAssertTrue(NeoCLISetup.autoUpdateEligible(
            name: "markcut", installedSource: "lalalic/markcut"))
        XCTAssertTrue(NeoCLISetup.autoUpdateEligible(
            name: "webhelm", installedSource: "lalalic/webhelm"))
        XCTAssertTrue(NeoCLISetup.autoUpdateEligible(
            name: "webhelm", installedSource: "lalalic/browser-workspace"))
        XCTAssertFalse(NeoCLISetup.autoUpdateEligible(
            name: "webhelm", installedSource: nil))
        XCTAssertFalse(NeoCLISetup.autoUpdateEligible(
            name: "markcut", installedSource: "other/repository"))
        XCTAssertFalse(NeoCLISetup.autoUpdateEligible(
            name: "unknown", installedSource: "other/repository"))
    }

    func testGlobalSkillsReadOnlyInventory() {
        XCTAssertEqual(NeoCLISetup.globalSkills(), ["events-bus", "daemon-service-manage", "webhelm", "agents-relay", "markcut"])
    }

    func testMarkcutPreviewRequiresInstalledMarkcutSkill() {
        XCTAssertEqual(NeoCLISetup.missingSkills(forTool: "markcut_preview", installed: []),
                       ["markcut"])
        XCTAssertTrue(NeoCLISetup.missingSkills(
            forTool: "markcut.preview", installed: ["markcut"]).isEmpty)
        XCTAssertTrue(NeoCLISetup.missingSkills(
            forTool: "unrelated_tool", installed: []).isEmpty)
    }

    func testAutoUpdateIsOptInAndDaily() {
        let suite = "NeoAutoUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(defaults.bool(forKey: NeoCLISetup.autoUpdateSkillsKey))
        XCTAssertFalse(defaults.bool(forKey: NeoCLISetup.autoUpdateProjectsKey))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(NeoCLISetup.updateDue(last: nil, now: now))
        XCTAssertFalse(NeoCLISetup.updateDue(last: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(NeoCLISetup.updateDue(last: now.addingTimeInterval(-86_401), now: now))
    }

    func testOptionalSkillCatalogDoesNotIncludeCoreDependencies() {
        XCTAssertEqual(Set(NeoCLISetup.optionalSkillSources.keys),
                       Set(["wechat-bro"]))
        XCTAssertEqual(Set(NeoCLISetup.requiredGlobalSkills),
                       Set(["events-bus", "daemon-service-manage", "webhelm", "agents-relay", "markcut"]))
        XCTAssertEqual(NeoCLISetup.managedSkillSources["markcut"], "lalalic/markcut")
        XCTAssertTrue(Set(NeoCLISetup.optionalSkillSources.keys)
            .isDisjoint(with: NeoCLISetup.requiredGlobalSkills))
        XCTAssertThrowsError(try NeoCLISetup.removeOptionalSkill("markcut"))
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
