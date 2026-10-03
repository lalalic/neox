import Foundation

enum NeoYSetupTopic: String, CaseIterable, Sendable {
    case overview, status, configuration, deployment, diagnostics, permissions, federation, features, events, capabilities, auth, roadmap
}

enum NeoYSetupCommand: Equatable, Sendable {
    case help(topic: NeoYSetupTopic?)
    case status
    case configuration
    case deploymentShow
    case deploymentSetPort(UInt16)
    case deploymentSetTunnel(NeoYTunnelMode)
    case deploymentSetTunnelName(String)
    case deploymentSetHostname(String)
    case diagnosticsEnable
    case diagnosticsDisable
    case diagnosticsSet(NeoYDiagnosticsSetting)
    case permissionsStatus
    case permissionOpen(NeoYPermissionKind)
    case mcpList
    case mcpAdd(name: String, url: String)
    case mcpRemove(String)
    case mcpEnable(name: String, enabled: Bool)
    case featureList
    case featureStatus(String)
    case featureInstall(String)
    case featureEnable(String, enabled: Bool)
    case featureUninstall(String)
    case featureConfigure(id: String, patchJSON: String)
    case featureAction(id: String, action: String)
    case featureSetup(String)
    case featureComplete(String)
    case eventsStatus
    case eventsSet(kind: NeoYImportantEventKind, enabled: Bool)
    case eventNotify(kind: NeoYImportantEventKind, title: String, body: String)
    case capabilityList
    case capabilitySet(NeoYOptionalCapability, enabled: Bool)
    case authShow
    case authRotate
}

enum NeoYSetupError: LocalizedError {
    case unknownCommand(String)
    case unknownTopic(String)
    case unexpectedArgument(String)
    case missingArgument(String)
    case unmatchedQuote
    case invalidValue(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let value): "unknown command '\(value)'; run 'help'"
        case .unknownTopic(let value):
            "unknown topic '\(value)'; supported topics: \(NeoYSetupTopic.allCases.map(\.rawValue).joined(separator: ", "))"
        case .unexpectedArgument(let value): "unexpected argument '\(value)'"
        case .missingArgument(let value): "missing argument: \(value)"
        case .unmatchedQuote: "unmatched quote"
        case .invalidValue(let value): value
        }
    }
}

enum NeoYSetupParser {
    static func parse(_ raw: String?) throws -> NeoYSetupCommand {
        var tokens = try tokenize(raw ?? "")
        while tokens.first == "setup" || tokens.first == "setup" { tokens.removeFirst() }
        guard let command = tokens.first else { return .help(topic: nil) }

        switch command {
        case "help": return try help(tokens)
        case "status":
            try exact(tokens, count: 1)
            return .status
        case "config":
            guard tokens == ["config", "show"] else { throw NeoYSetupError.unknownCommand(tokens.joined(separator: " ")) }
            return .configuration
        case "deployment": return try deployment(tokens)
        case "diagnostics": return try diagnostics(tokens)
        case "permissions": return try permissions(tokens)
        case "mcp": return try mcp(tokens)
        case "feature", "features": return try feature(tokens)
        case "events": return try events(tokens)
        case "capability", "capabilities": return try capability(tokens)
        case "auth": return try auth(tokens)
        default: throw NeoYSetupError.unknownCommand(command)
        }
    }

    private static func help(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count <= 2 else { throw NeoYSetupError.unexpectedArgument(tokens[2]) }
        guard tokens.count == 2 else { return .help(topic: nil) }
        guard let topic = NeoYSetupTopic(rawValue: tokens[1]) else { throw NeoYSetupError.unknownTopic(tokens[1]) }
        return .help(topic: topic)
    }

    private static func deployment(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { return .deploymentShow }
        switch tokens[1] {
        case "show":
            try exact(tokens, count: 2)
            return .deploymentShow
        case "set":
            guard tokens.count == 4 else {
                throw NeoYSetupError.missingArgument("deployment set <port|tunnel|tunnel-name|hostname> <value>")
            }
            switch tokens[2] {
            case "port":
                guard let value = UInt16(tokens[3]), value > 0 else {
                    throw NeoYSetupError.invalidValue("port must be 1...65535")
                }
                return .deploymentSetPort(value)
            case "tunnel":
                guard let value = NeoYTunnelMode(rawValue: tokens[3]) else {
                    throw NeoYSetupError.invalidValue("tunnel must be off, quick, or named")
                }
                return .deploymentSetTunnel(value)
            case "tunnel-name":
                return .deploymentSetTunnelName(tokens[3])
            case "hostname":
                return .deploymentSetHostname(tokens[3])
            default:
                throw NeoYSetupError.unknownCommand(tokens.prefix(3).joined(separator: " "))
            }
        default:
            throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func diagnostics(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { throw NeoYSetupError.missingArgument("diagnostics subcommand") }
        switch tokens[1] {
        case "enable":
            try exact(tokens, count: 2)
            return .diagnosticsEnable
        case "disable":
            try exact(tokens, count: 2)
            return .diagnosticsDisable
        case "set":
            guard tokens.count == 4 else { throw NeoYSetupError.missingArgument("diagnostics set <level|retention-days> <value>") }
            switch tokens[2] {
            case "level":
                guard let level = NeoYDiagnosticsLevel(rawValue: tokens[3]) else {
                    throw NeoYControlPlaneError.invalidDiagnosticsLevel(tokens[3])
                }
                return .diagnosticsSet(.level(level))
            case "retention-days":
                guard let days = Int(tokens[3]) else { throw NeoYControlPlaneError.invalidRetentionDays(0) }
                guard (1...365).contains(days) else { throw NeoYControlPlaneError.invalidRetentionDays(days) }
                return .diagnosticsSet(.retentionDays(days))
            default: throw NeoYControlPlaneError.invalidDiagnosticsProperty(tokens[2])
            }
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func permissions(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { return .permissionsStatus }
        switch tokens[1] {
        case "status":
            try exact(tokens, count: 2)
            return .permissionsStatus
        case "open":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("permissions open <kind>") }
            guard let kind = NeoYPermissionKind(rawValue: tokens[2]) else {
                throw NeoYSetupError.invalidValue("unknown permission '\(tokens[2])'")
            }
            return .permissionOpen(kind)
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func mcp(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { throw NeoYSetupError.missingArgument("mcp subcommand") }
        switch tokens[1] {
        case "list":
            try exact(tokens, count: 2)
            return .mcpList
        case "add":
            guard tokens.count == 4 else { throw NeoYSetupError.missingArgument("mcp add <name> <http(s)-url|stdio-url>") }
            return .mcpAdd(name: tokens[2], url: tokens[3])
        case "remove":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("mcp remove <name>") }
            return .mcpRemove(tokens[2])
        case "enable", "disable":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("mcp \(tokens[1]) <name>") }
            return .mcpEnable(name: tokens[2], enabled: tokens[1] == "enable")
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func feature(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { return .featureList }
        switch tokens[1] {
        case "list":
            try exact(tokens, count: 2)
            return .featureList
        case "status":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("feature status <id>") }
            return .featureStatus(tokens[2])
        case "install":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("feature install <id>") }
            return .featureInstall(tokens[2])
        case "enable", "disable":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("feature \(tokens[1]) <id>") }
            return .featureEnable(tokens[2], enabled: tokens[1] == "enable")
        case "uninstall":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("feature uninstall <id>") }
            return .featureUninstall(tokens[2])
        case "configure":
            guard tokens.count == 4 else { throw NeoYSetupError.missingArgument("feature configure <id> '<json-object-patch>'") }
            return .featureConfigure(id: tokens[2], patchJSON: tokens[3])
        case "start", "stop", "restart", "doctor":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("feature \(tokens[1]) <id>") }
            return .featureAction(id: tokens[2], action: tokens[1])
        case "setup":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("feature setup <id>") }
            return .featureSetup(tokens[2])
        case "complete":
            guard tokens.count == 3 else { throw NeoYSetupError.missingArgument("feature complete <id>") }
            return .featureComplete(tokens[2])
        default:
            throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func events(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { return .eventsStatus }
        switch tokens[1] {
        case "status":
            try exact(tokens, count: 2)
            return .eventsStatus
        case "enable", "disable":
            guard tokens.count == 3, let kind = NeoYImportantEventKind(rawValue: tokens[2]) else {
                throw NeoYSetupError.invalidValue("event kind must be blocked, failure, or completed")
            }
            return .eventsSet(kind: kind, enabled: tokens[1] == "enable")
        case "notify":
            guard tokens.count >= 5, let kind = NeoYImportantEventKind(rawValue: tokens[2]) else {
                throw NeoYSetupError.missingArgument("events notify <kind> <title> <body...>")
            }
            return .eventNotify(kind: kind, title: tokens[3], body: tokens.dropFirst(4).joined(separator: " "))
        default: throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func capability(_ tokens: [String]) throws -> NeoYSetupCommand {
        guard tokens.count >= 2 else { return .capabilityList }
        switch tokens[1] {
        case "list":
            try exact(tokens, count: 2)
            return .capabilityList
        case "enable", "disable":
            guard tokens.count == 3, let capability = NeoYOptionalCapability(rawValue: tokens[2]) else {
                throw NeoYSetupError.invalidValue(
                    "capability must be one of: " + NeoYOptionalCapability.allCases.map(\.rawValue).joined(separator: ", "))
            }
            return .capabilitySet(capability, enabled: tokens[1] == "enable")
        default:
            throw NeoYSetupError.unknownCommand(tokens.prefix(2).joined(separator: " "))
        }
    }

    private static func auth(_ tokens: [String]) throws -> NeoYSetupCommand {
        if tokens == ["auth", "show"] { return .authShow }
        if tokens == ["auth", "rotate"] || tokens == ["auth", "revoke"] { return .authRotate }
        throw NeoYSetupError.unknownCommand(tokens.joined(separator: " "))
    }

    private static func exact(_ tokens: [String], count: Int) throws {
        if tokens.count > count { throw NeoYSetupError.unexpectedArgument(tokens[count]) }
        if tokens.count < count { throw NeoYSetupError.missingArgument("argument") }
    }

    private static func tokenize(_ raw: String) throws -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        for character in raw {
            if character == "\"" || character == "'" {
                if quote == nil { quote = character; continue }
                if quote == character { quote = nil; continue }
            }
            if character.isWhitespace && quote == nil {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        if quote != nil { throw NeoYSetupError.unmatchedQuote }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }
}

enum NeoYRuntimeState: String, Codable, Sendable {
    case ready, degraded
}

struct NeoYRuntimeEndpoint: Codable, Equatable, Sendable {
    let name: String
    let url: String
    let isRunning: Bool
    let error: String?
}

struct NeoYPhonePairingSelection: Codable, Equatable, Sendable {
    let isSelected: Bool
    let name: String?
    let kind: String?
    let url: String?

    static let unavailable = NeoYPhonePairingSelection(isSelected: false, name: nil, kind: nil, url: nil)
}

struct NeoYRuntimeStatus: Codable, Equatable, Sendable {
    let state: NeoYRuntimeState
    let version: String
    let bundleIdentifier: String
    let startupMode: String
    let mcp: NeoYRuntimeEndpoint
    let neoXPairing: NeoYPhonePairingSelection
    let handoff: NeoYRuntimeEndpoint
    let capabilities: [String]
    var controlPlane: NeoYControlPlaneHealth?
}

struct NeoYConfigurationSnapshot: Codable, Equatable, Sendable {
    let configuration: NeoYControlPlaneConfiguration
    let controlPlane: NeoYControlPlaneHealth
}

struct NeoYConfigurationMutationResult: Codable, Equatable, Sendable {
    let ok: Bool
    let operation: String
    let error: String?
    let configuration: NeoYControlPlaneConfiguration
    let controlPlane: NeoYControlPlaneHealth
}

actor NeoYSetupService {
    private let makeStatus: @Sendable () async -> NeoYRuntimeStatus
    private let controlPlane: NeoYControlPlaneService
    private let runtime: NeoYRuntimeControl?
    private let onDeploymentChanged: (@Sendable () async -> Void)?
    private let onCapabilitiesChanged: (@Sendable (NeoYControlPlaneConfiguration) async -> Void)?

    init(
        makeStatus: @escaping @Sendable () async -> NeoYRuntimeStatus,
        controlPlane: NeoYControlPlaneService = NeoYControlPlaneService(
            store: NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory)
        ),
        runtime: NeoYRuntimeControl? = nil,
        onDeploymentChanged: (@Sendable () async -> Void)? = nil,
        onCapabilitiesChanged: (@Sendable (NeoYControlPlaneConfiguration) async -> Void)? = nil
    ) {
        self.makeStatus = makeStatus
        self.controlPlane = controlPlane
        self.runtime = runtime
        self.onDeploymentChanged = onDeploymentChanged
        self.onCapabilitiesChanged = onCapabilitiesChanged
    }

    func currentConfiguration() async -> NeoYControlPlaneConfiguration {
        await controlPlane.currentConfiguration()
    }

    func execute(_ command: NeoYSetupCommand) async -> String {
        switch command {
        case .help(let topic): return Self.help(topic)
        case .status:
            var status = await makeStatus()
            status.controlPlane = await controlPlane.currentHealth()
            return Self.json(status)
        case .configuration:
            return Self.json(await snapshot())
        case .deploymentShow:
            return Self.json(NeoYDeploymentSettingsStore.load())
        case .deploymentSetPort(let port):
            return deploymentMutation("deployment.set.port") { $0.mcpPort = port }
        case .deploymentSetTunnel(let mode):
            return deploymentMutation("deployment.set.tunnel") { $0.tunnelMode = mode }
        case .deploymentSetTunnelName(let name):
            return deploymentMutation("deployment.set.tunnel-name") { $0.tunnelName = name }
        case .deploymentSetHostname(let hostname):
            return deploymentMutation("deployment.set.hostname") { $0.publicHostname = hostname }
        case .diagnosticsEnable:
            return await mutate("diagnostics.enable") { try await self.controlPlane.setDiagnosticsEnabled(true) }
        case .diagnosticsDisable:
            return await mutate("diagnostics.disable") { try await self.controlPlane.setDiagnosticsEnabled(false) }
        case .diagnosticsSet(let setting):
            return await mutate("diagnostics.set") { try await self.controlPlane.setDiagnostics(setting) }
        case .permissionsStatus:
            return Self.json(await runtime?.permissions() ?? [])
        case .permissionOpen(let kind):
            return Self.json(JSONValue.object(["opened": .bool(await runtime?.openPermission(kind) ?? false), "permission": .string(kind.rawValue)]))
        case .mcpList:
            let configuration = await controlPlane.currentConfiguration()
            return Self.json(await runtime?.federationStatus(configuration) ?? [])
        case .mcpAdd(let name, let url):
            return await mutateAndReconcile("mcp.add") {
                try await self.controlPlane.upsertMCP(.init(name: name, url: url))
            }
        case .mcpRemove(let name):
            return await mutateAndReconcile("mcp.remove") { try await self.controlPlane.removeMCP(name) }
        case .mcpEnable(let name, let enabled):
            return await mutateAndReconcile("mcp.\(enabled ? "enable" : "disable")") {
                try await self.controlPlane.setMCPEnabled(name, enabled: enabled)
            }
        case .featureList:
            let installed = await NeoYFeatureManager.shared.records()
            let byID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })
            let rows = NeoYFeatureCatalog.all.map { item in
                byID[item.id] ?? NeoYFeatureRecord(id: item.id, package: item.package, version: nil, enabled: false, state: .available, provider: nil, mcpURL: nil, error: nil)
            }
            return Self.json(rows)
        case .featureStatus(let id):
            if let record = await NeoYFeatureManager.shared.record(id: id) { return Self.json(record) }
            if let item = NeoYFeatureCatalog.all.first(where: { $0.id == id }) {
                return Self.json(NeoYFeatureRecord(id: item.id, package: item.package, version: nil, enabled: false, state: .available, provider: nil, mcpURL: nil, error: nil))
            }
            return "Error: unknown feature '\(id)'"
        case .featureInstall(let id):
            guard let item = NeoYFeatureCatalog.all.first(where: { $0.id == id }) else { return "Error: unknown feature '\(id)'" }
            do { return Self.json(try await NeoYFeatureManager.shared.setEnabled(item, enabled: true)) }
            catch { return "Error: \(error.localizedDescription)" }
        case .featureEnable(let id, let enabled):
            guard let item = NeoYFeatureCatalog.all.first(where: { $0.id == id }) else { return "Error: unknown feature '\(id)'" }
            do { return Self.json(try await NeoYFeatureManager.shared.setEnabled(item, enabled: enabled)) }
            catch { return "Error: \(error.localizedDescription)" }
        case .featureUninstall(let id):
            guard let item = NeoYFeatureCatalog.all.first(where: { $0.id == id }) else { return "Error: unknown feature '\(id)'" }
            do { try await NeoYFeatureManager.shared.uninstall(item); return "{\"ok\":true,\"id\":\"\(id)\"}" }
            catch { return "Error: \(error.localizedDescription)" }
        case .featureConfigure(let id, let patchJSON):
            do { return Self.json(try await NeoYFeatureManager.shared.configure(id: id, patchJSON: patchJSON)) }
            catch { return "Error: \(error.localizedDescription)" }
        case .featureAction(let id, let action):
            do { return Self.json(try await NeoYFeatureManager.shared.action(id: id, action: action)) }
            catch { return "Error: \(error.localizedDescription)" }
        case .featureSetup(let id):
            do { try await NeoYFeatureManager.shared.startSetup(id: id); return "{\"ok\":true,\"id\":\"\(id)\",\"state\":\"configuring\"}" }
            catch { return "Error: \(error.localizedDescription)" }
        case .featureComplete(let id):
            do { return Self.json(try await NeoYFeatureManager.shared.completeSetup(id: id)) }
            catch { return "Error: \(error.localizedDescription)" }
        case .eventsStatus:
            return Self.json((await controlPlane.currentConfiguration()).events)
        case .eventsSet(let kind, let enabled):
            return await mutate("events.\(enabled ? "enable" : "disable")") {
                try await self.controlPlane.setEvent(kind, enabled: enabled)
            }
        case .eventNotify(let kind, let title, let body):
            do {
                guard let runtime else { throw NeoYRuntimeControlError.event("runtime event bridge is unavailable") }
                let config = await controlPlane.currentConfiguration()
                return try await runtime.iphoneNotify(kind: kind, title: title, body: body, configuration: config)
            } catch {
                return Self.json(JSONValue.object(["delivered": .bool(false), "error": .string(error.localizedDescription)]))
            }
        case .capabilityList:
            let configuration = await controlPlane.currentConfiguration()
            let rows = NeoYOptionalCapability.allCases.map { capability in
                [
                    "name": capability.rawValue,
                    "enabled": configuration.capabilities.isEnabled(capability) ? "true" : "false",
                    "kind": "optional"
                ]
            }
            return Self.json(rows)
        case .capabilitySet(let capability, let enabled):
            let result = await mutate("capability.\(enabled ? "enable" : "disable")") {
                try await self.controlPlane.setCapability(capability, enabled: enabled)
            }
            if let onCapabilitiesChanged {
                let configuration = await controlPlane.currentConfiguration()
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    await onCapabilitiesChanged(configuration)
                }
            }
            return result
        case .authShow:
            let settings = NeoYDeploymentSettingsStore.load()
            return Self.json([
                "local_core_url": NeoYCoreAuth.url(settings.localMCPURL),
                "public_core_url": settings.publicMCPURL.map(NeoYCoreAuth.url) ?? "",
                "token": NeoYCoreAuth.token()
            ])
        case .authRotate:
            let token = NeoYCoreAuth.rotateToken()
            if let onDeploymentChanged {
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    await onDeploymentChanged()
                }
            }
            return Self.json([
                "revoked": "true",
                "token": token
            ])
        }
    }

    private func deploymentMutation(
        _ operation: String,
        mutation: (inout NeoYDeploymentSettings) -> Void
    ) -> String {
        do {
            var settings = NeoYDeploymentSettingsStore.load()
            mutation(&settings)
            try NeoYDeploymentSettingsStore.save(settings)
            if let onDeploymentChanged {
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    await onDeploymentChanged()
                }
            }
            return Self.json(JSONValue.object([
                "ok": .bool(true),
                "operation": .string(operation),
                "local_mcp_url": .string(settings.localMCPURL),
                "public_mcp_url": settings.publicMCPURL.map(JSONValue.string) ?? .null
            ]))
        } catch {
            return Self.json(JSONValue.object([
                "ok": .bool(false),
                "operation": .string(operation),
                "error": .string(error.localizedDescription)
            ]))
        }
    }

    private func snapshot() async -> NeoYConfigurationSnapshot {
        NeoYConfigurationSnapshot(
            configuration: await controlPlane.currentConfiguration(),
            controlPlane: await controlPlane.currentHealth())
    }

    private func mutate(
        _ operation: String,
        mutation: @Sendable () async throws -> NeoYControlPlaneConfiguration
    ) async -> String {
        do {
            let configuration = try await mutation()
            return Self.json(NeoYConfigurationMutationResult(
                ok: true, operation: operation, error: nil, configuration: configuration,
                controlPlane: await controlPlane.currentHealth()))
        } catch {
            return Self.json(NeoYConfigurationMutationResult(
                ok: false, operation: operation, error: error.localizedDescription,
                configuration: await controlPlane.currentConfiguration(),
                controlPlane: await controlPlane.currentHealth()))
        }
    }

    private func mutateAndReconcile(
        _ operation: String,
        mutation: @Sendable () async throws -> NeoYControlPlaneConfiguration
    ) async -> String {
        do {
            let configuration = try await mutation()
            await runtime?.reconcile(configuration)
            return Self.json(NeoYConfigurationMutationResult(
                ok: true, operation: operation, error: nil, configuration: configuration,
                controlPlane: await controlPlane.currentHealth()))
        } catch {
            return Self.json(NeoYConfigurationMutationResult(
                ok: false, operation: operation, error: error.localizedDescription,
                configuration: await controlPlane.currentConfiguration(),
                controlPlane: await controlPlane.currentHealth()))
        }
    }

    static func help(_ topic: NeoYSetupTopic?) -> String {
        return switch topic {
        case .overview:
            "NeoY is Neo's signed menu-bar Mac runtime. One setup CLI configures native trust, supervised services, federated MCPs, diagnostics, and NeoX events."
        case .status:
            "'status' returns runtime, MCP, NeoX pairing/handoff, capability, and control-plane health."
        case .configuration:
            "'config show' returns versioned validated configuration without making storage paths part of the normal UX."
        case .deployment:
            """
            deployment show
            deployment set port <1...65535>
            deployment set tunnel <off|quick|named>
            deployment set tunnel-name <name>
            deployment set hostname <host>
            Changes are persisted and the MCP/tunnel runtime is reconciled automatically.
            """
        case .diagnostics:
            "diagnostics enable|disable; diagnostics set level <info|warning|error>; diagnostics set retention-days <1...365>"
        case .permissions:
            "permissions status; permissions open <accessibility|screen-recording|camera|microphone|notifications|local-network>. Human approval remains required."
        case .federation:
            """
            mcp list
            mcp add <name> <http(s)-mcp-url|stdio:///absolute/executable?arg=...>
            mcp remove|enable|disable <name>
            Enabled tools appear as mcp.<server>.<tool>. HTTP MCPs connect by URL; stdio MCPs are launched and supervised by federation itself.
            """
        case .features:
            """
            feature list
            feature status <id>
            feature install|enable|disable|uninstall <id>
            feature configure <id> '<json-object-patch>'
            feature start|stop|restart|doctor <id>
            feature setup <id> — open the feature's temporary ChatGPT setup conversation.
            feature complete <id> — run doctor, start the service, verify MCP health, and mark setup ready.
            Optional features install from their published package; local MCP is automatic and remote exposure is separately opt-in.
            """
        case .events:
            """
            events status
            events enable|disable <blocked|failure|completed>
            events notify <kind> "<title>" <body...>
            Only policy-enabled important events are forwarded to the paired NeoX runtime.
            """
        case .capabilities:
            """
            capability list
            capability enable|disable <accessibility-computer|demo-recording|capture-tour|phone-integration|public-tunnel>
            Optional first-party capabilities are enabled by default. Core setup/exec/fs/codex/node capabilities cannot be disabled.
            """
        case .auth:
            """
            auth show — return the current Core token and tokenized local/public MCP URLs.
            auth rotate — revoke the current token and issue a replacement immediately.
            auth revoke — alias for auth rotate.
            """
        case .roadmap:
            "v2 core is implemented around typed persistence, native permission guidance, HTTP/stdio MCP federation, and pairing-aware NeoX important-event delivery. Signed installed-app permission/login E2E still requires the actual installed identity and human TCC approvals."
        case nil:
            """
            NeoY setup CLI
              help [topic]
              status
              config show
              deployment show|set ...
              diagnostics ...
              permissions status|open ...
              mcp list|add|remove|enable|disable ...
              feature list|status|install|enable|disable|uninstall|configure|start|stop|restart|doctor|setup|complete ...
              events status|enable|disable|notify ...
              capability list|enable|disable ...
              auth show|rotate|revoke

            Run 'help <topic>' for exact grammar. Runtime help is authoritative for the installed NeoY version.
            """
        }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{\"state\":\"degraded\",\"error\":\"encoding failed\"}" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum NeoYSetupTools {
    static func tools(service: NeoYSetupService) -> [ToolDefinition] {
        [ToolDefinition(
            name: "setup",
            description: "NeoY setup/control CLI. Run without command or run 'help' for authoritative runtime commands covering status, permissions, MCP federation, diagnostics, optional capabilities, Core auth, and important NeoX events.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("CLI-like NeoY setup command; omit for help"),
                    ]),
                ]),
            ])
        ) { args in
            let raw: String?
            if case .object(let object) = args, case .string(let value)? = object["command"] { raw = value }
            else { raw = nil }
            do { return await service.execute(try NeoYSetupParser.parse(raw)) }
            catch { return "Error: \(error.localizedDescription)" }
        }]
    }
}
