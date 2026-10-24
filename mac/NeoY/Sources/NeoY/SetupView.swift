import Foundation
import AppKit
import SwiftUI

@MainActor
final class NeoYSetupModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case connections = "Connections"
        case features = "Features"
        case deployment = "Deployment"
        var id: String { rawValue }
    }

    enum RemoteMode: String, CaseIterable, Identifiable {
        case temporary, ownDomain
        var id: String { rawValue }
    }

    @Published var tab: Tab = .connections
    @Published var portText = String(NeoYDeploymentSettings.defaultPort)
    @Published var remoteEnabled = false
    @Published var remoteMode: RemoteMode = .temporary
    @Published private(set) var appliedRemoteMode: RemoteMode = .temporary
    @Published var publicHostname = ""
    @Published var remoteTools: Set<String> = []
    @Published private(set) var remoteToolOptions: [String] = []
    @Published var remoteProviders: Set<String> = []
    @Published private(set) var featureRecords: [NeoYFeatureRecord] = []
    @Published private(set) var nativeEnabledTools: Set<String> = []
    @Published private(set) var disabledDiscoveredTools: Set<String> = []
    @Published private(set) var discoveredMCPTools: [String] = []
    @Published private(set) var remoteProviderOptions: [String] = []
    @Published private(set) var oauthClientID = ""
    @Published private(set) var oauthToken = ""
    @Published var result = ""
    @Published var coreVersionInput = "latest"
    @Published var coreRuntimeStatus = NeoYManagedCoreRuntime.active()?.lastPathComponent ?? "bootstrap Core (not installed)"
    @Published var neoCLIReport = "Checking Neo CLI…"
    @Published var toolkitUninstallable = false
    @Published var toolkitInstalled = false
    @Published var toolkitEnabled = UserDefaults.standard.object(forKey: "NeoProjectsToolkitEnabled") as? Bool ?? true
    @Published var globalSkills = NeoCLISetup.globalSkills()
    @Published var optionalSkills: Set<String> = []
    @Published private(set) var projectNames: [String] = []
    @Published private(set) var clusterNodes: [NeoYNodeConfiguration] = []
    @Published var newNodeName = ""
    @Published var newNodeURL = ""
    @Published var newNodeToken = ""
    @Published var isBusy = false
    @Published private(set) var permissions: [NeoYPermissionStatus] = []

    init() {
        reload()
        Task {
            await refreshPermissions()
            await refreshFeatures()
            refreshNativeTools()
            await refreshMCPTools()
            refreshProjects()
            refreshClusterNodes()
            refreshNeoCLI()
        }
    }

    func refreshCoreRuntime() {
        coreRuntimeStatus = NeoYManagedCoreRuntime.active()?.lastPathComponent ?? "bootstrap Core (not installed)"
    }

    func changeCoreRuntime(rollback: Bool = false) {
        guard !isBusy else { return }
        let version = coreVersionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true
        Task.detached { [weak self] in
            let message: String
            do {
                let selected = try rollback
                    ? NeoYManagedCoreRuntime.rollbackPrevious()
                    : NeoYManagedCoreRuntime.registryUpgrade(version: version)
                message = "Core switched to \(selected); reconnecting Core provider"
                await MainActor.run {
                    NotificationCenter.default.post(name: Notification.Name("neoYCoreRuntimeChanged"), object: nil)
                }
            } catch {
                message = "Core unchanged: \(error.localizedDescription)"
            }
            await MainActor.run {
                self?.result = message
                self?.refreshCoreRuntime()
                self?.isBusy = false
            }
        }
    }

    func refreshNeoCLI() {
        Task.detached { [weak self] in
            let report = NeoCLISetup.report()
            let canUninstall = NeoCLISetup.managedToolkitInstalled()
            let installed = NeoCLISetup.cliPath() != nil
            let skills = NeoCLISetup.allInstalledGlobalSkills()
            await MainActor.run {
                self?.neoCLIReport = report
                self?.toolkitUninstallable = canUninstall
                self?.toolkitInstalled = installed
                self?.optionalSkills = skills
            }
        }
    }

    func refreshProjects() {
        Task.detached { [weak self] in
            let names = NeoCLISetup.projectNames()
            await MainActor.run { self?.projectNames = names }
        }
    }

    func refreshClusterNodes() {
        Task {
            let localURL = NeoYDeploymentSettingsStore.load().localMCPURL
            clusterNodes = await NeoYNodeStore().list().filter { !$0.url.hasPrefix(localURL) }
        }
    }

    func addClusterNode() {
        guard !isBusy else { return }
        let name = newNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newNodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              let parsed = URLComponents(string: url),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host, !host.isEmpty,
              !clusterNodes.contains(where: { $0.name == name }),
              url != NeoYDeploymentSettingsStore.load().localMCPURL else {
            result = "Enter a unique node name and a valid remote MCP URL."
            return
        }
        isBusy = true
        let token = newNodeToken.isEmpty ? nil : newNodeToken
        Task {
            do {
                try await NeoYNodeService().pairNode(name: name, url: url, token: token)
                newNodeName = ""
                newNodeURL = ""
                newNodeToken = ""
                refreshClusterNodes()
                result = "Node \(name) added."
            } catch { result = "Node not added: \(error.localizedDescription)" }
            isBusy = false
        }
    }

    func removeClusterNode(_ name: String) {
        guard !isBusy, clusterNodes.contains(where: { $0.name == name }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove node \(name)?"
        alert.informativeText = "Remove this node from Neo's trusted cluster list. The remote machine and its services are unchanged."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true
        Task {
            do {
                try await NeoYNodeStore().remove(name)
                refreshClusterNodes()
                result = "Node \(name) removed."
            } catch { result = "Node not removed: \(error.localizedDescription)" }
            isBusy = false
        }
    }

    func refreshMCPTools() async {
        let urlString = NeoYDeploymentSettingsStore.load().localMCPURL
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"jsonrpc":"2.0","id":"feature-tools","method":"tools/list","params":{}}"#.data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let rpc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = rpc["result"] as? [String: Any],
                  let tools = result["tools"] as? [[String: Any]] else { return }
            discoveredMCPTools = tools.compactMap { $0["name"] as? String }.sorted()
        } catch {
            result = "Tool discovery failed: \(error.localizedDescription)"
        }
    }

    var visibleMCPFeatureTools: [String] {
        let candidate = Set(discoveredMCPTools)
            .union(NeoYRemoteToolCatalog.nativeOptionalTools.keys)
            .union(disabledDiscoveredTools)
        return candidate.filter { name in
            if NeoYCoreRuntime.toolNames.contains(name) { return false }
            if ["events", "neoy.ui_smoke", "mcp.temp-files"].contains(name) { return false }
            if name.hasPrefix("markcut.") || name.hasPrefix("family-tutor.") || name == "mcp.family-tutor" {
                return false // Shown as their owning Feature, not repeated as individual tools.
            }
            return true
        }.sorted()
    }

    func refreshNativeTools() {
        let store = NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory)
        guard let configuration = try? store.loadOrCreate().document.configuration else { return }
        disabledDiscoveredTools = configuration.capabilities.disabledTools
        nativeEnabledTools = Set(NeoYRemoteToolCatalog.nativeOptionalTools.compactMap { tool, capability in
            configuration.capabilities.isEnabled(capability) ? tool : nil
        })
    }

    func setNativeTool(_ tool: String, enabled: Bool) {
        guard !isBusy, let capability = NeoYRemoteToolCatalog.nativeOptionalTools[tool] else { return }
        isBusy = true
        Task {
            do {
                let control = NeoYControlPlaneService(
                    store: NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory))
                _ = try await control.setCapability(capability, enabled: enabled)
                NotificationCenter.default.post(name: .neoYFeaturesChanged, object: nil)
                result = "\(tool) \(enabled ? "enabled" : "disabled")."
            } catch { result = error.localizedDescription }
            refreshNativeTools()
            refreshRemoteToolOptions()
            await refreshMCPTools()
            isBusy = false
        }
    }

    func setDiscoveredTool(_ name: String, enabled: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do {
                let control = NeoYControlPlaneService(
                    store: NeoYFileControlPlaneStore(directory: NeoYPaths.supportDirectory))
                _ = try await control.setToolEnabled(name, enabled: enabled)
                NotificationCenter.default.post(name: .neoYFeaturesChanged, object: nil)
                result = "\(name) \(enabled ? "enabled" : "disabled")."
            } catch { result = error.localizedDescription }
            refreshNativeTools()
            await refreshMCPTools()
            isBusy = false
        }
    }

    func setToolkitEnabled(_ enabled: Bool) {
        guard !isBusy else { return }
        toolkitEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "NeoProjectsToolkitEnabled")
        if enabled && !toolkitInstalled { setupNeoCLI() }
    }

    func installOptionalSkill(_ name: String) {
        guard !isBusy, let source = NeoCLISetup.optionalSkillSources[name] else { return }
        isBusy = true
        Task.detached { [weak self] in
            let message: String
            do {
                _ = try NeoCLISetup.runSkills(["add", source, "-g", "-y", "-s", name])
                message = "Installed \(name)."
            } catch { message = "Installation failed: \(error.localizedDescription)" }
            await MainActor.run {
                self?.result = message
                self?.refreshNeoCLI()
                self?.isBusy = false
            }
        }
    }

    func removeOptionalSkill(_ name: String) {
        guard !isBusy, optionalSkills.contains(name) else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(name)?"
        alert.informativeText = "This removes the global Skill from agent installations. Project files are unchanged."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true
        Task.detached { [weak self] in
            let message: String
            do {
                try NeoCLISetup.removeOptionalSkill(name)
                message = "Uninstalled \(name)."
            } catch { message = "Uninstall failed: \(error.localizedDescription)" }
            await MainActor.run {
                self?.result = message
                self?.refreshNeoCLI()
                self?.isBusy = false
            }
        }
    }

    func setupNeoCLI() {
        isBusy = true
        Task.detached { [weak self] in
            let message = NeoCLISetup.setup()
            await MainActor.run {
                self?.result = message
                self?.refreshNeoCLI()
                self?.refreshProjects()
                self?.isBusy = false
            }
        }
    }

    func uninstallNeoToolkit() {
        guard !isBusy, toolkitUninstallable else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Neo Project Toolkit?"
        alert.informativeText = "Remove the global @lalalic/neo npm package. Developer links and mandatory Neo Skills are preserved."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true
        Task.detached { [weak self] in
            let message: String
            do { message = try NeoCLISetup.uninstallManagedToolkit() }
            catch { message = "Uninstall failed: \(error.localizedDescription)" }
            await MainActor.run {
                self?.result = message
                self?.refreshNeoCLI()
                self?.refreshProjects()
                self?.isBusy = false
            }
        }
    }

    func reload() {
        let value = NeoYDeploymentSettingsStore.load()
        portText = String(value.mcpPort)
        remoteEnabled = value.tunnelMode != .off
        let preferred = value.preferredTunnelMode ?? value.tunnelMode
        remoteMode = preferred == .named ? .ownDomain : .temporary
        appliedRemoteMode = remoteMode
        publicHostname = value.publicHostname
        remoteTools = value.enabledRemoteTools
        refreshRemoteToolOptions()
        remoteProviders = value.enabledRemoteProviders
        let credentials = NeoYMCPPluginCredentials.current()
        oauthClientID = credentials.clientID
        oauthToken = credentials.token
    }

    var localMCPURL: String {
        "http://127.0.0.1:\(portText)/mcp"
    }

    var remoteMCPURL: String {
        let value = NeoYDeploymentSettingsStore.load()
        return value.publicMCPURL ?? "Not connected"
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func applyPort() {
        guard let port = UInt16(portText), port > 0 else {
            result = "Port must be 1–65535."
            reload()
            return
        }
        do {
            var value = NeoYDeploymentSettingsStore.load()
            guard value.mcpPort != port else { return }
            value.mcpPort = port
            try NeoYDeploymentSettingsStore.save(value)
            NotificationCenter.default.post(name: .neoYDeploymentSettingsChanged, object: nil)
            result = "MCP port changed to \(port)."
        } catch {
            result = error.localizedDescription
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        do {
            let current = NeoYDeploymentSettingsStore.load()
            let value = try current.settingRemoteEnabled(enabled)
            try NeoYDeploymentSettingsStore.save(value)
            remoteEnabled = enabled
            NotificationCenter.default.post(name: .neoYDeploymentSettingsChanged, object: nil)
            result = enabled ? "Remote access is starting." : "Remote access stopped."
        } catch {
            result = error.localizedDescription
        }
    }

    func setRemoteMode(_ mode: RemoteMode) {
        remoteMode = mode
        // A selected mode is a draft. Only Apply changes the live tunnel.
    }

    var hasPendingRemoteAddress: Bool {
        if remoteMode != appliedRemoteMode { return true }
        guard remoteMode == .ownDomain else { return false }
        return publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            != NeoYDeploymentSettingsStore.load().publicHostname
    }

    func applyRemoteMode() {
        do {
            let mode: NeoYTunnelMode = remoteMode == .ownDomain ? .named : .quick
            let value = try NeoYDeploymentSettingsStore.load()
                .applyingRemoteAddress(mode, hostname: publicHostname, enabled: remoteEnabled)
            try NeoYDeploymentSettingsStore.save(value)
            appliedRemoteMode = remoteMode
            if remoteEnabled { NotificationCenter.default.post(name: .neoYDeploymentSettingsChanged, object: nil) }
            result = remoteEnabled ? "Remote configuration applied; connection is updating." : "Remote mode saved; enable remote MCP to connect."
        } catch { result = error.localizedDescription }
    }

    func applyHostname() {
        remoteMode = .ownDomain
        applyRemoteMode()
    }

    func setRemoteTool(_ tool: String, enabled: Bool) {
        if enabled { remoteTools.insert(tool) }
        else { remoteTools.remove(tool) }
        persistRemoteSettings(restartServer: true)
    }

    func setAllRemoteTools(_ enabled: Bool) {
        remoteTools = enabled ? Set(remoteToolOptions) : []
        remoteProviders = enabled ? Set(remoteProviderOptions) : []
        persistRemoteSettings(restartServer: true)
    }

    private func refreshRemoteToolOptions() {
        let controlPlaneURL = NeoYPaths.supportDirectory.appendingPathComponent("control-plane.json")
        let configuration = (try? Data(contentsOf: controlPlaneURL))
            .flatMap { try? JSONDecoder().decode(NeoYControlPlaneDocument.self, from: $0).configuration }
            ?? NeoYControlPlaneConfiguration()
        remoteToolOptions = NeoYRemoteToolCatalog.availableToolNames(configuration: configuration)
        remoteTools = remoteTools.intersection(Set(remoteToolOptions))
    }

    func setRemoteProvider(_ provider: String, enabled: Bool) {
        if enabled { remoteProviders.insert(provider) }
        else { remoteProviders.remove(provider) }
        persistRemoteSettings(restartServer: true)
    }

    func refreshFeatures() async {
        featureRecords = await NeoYFeatureManager.shared.records()
        var providers = Set(featureRecords.filter { $0.enabled }.compactMap(\.provider))
        let controlPlaneURL = NeoYPaths.supportDirectory.appendingPathComponent("control-plane.json")
        if let data = try? Data(contentsOf: controlPlaneURL),
           let document = try? JSONDecoder().decode(NeoYControlPlaneDocument.self, from: data) {
            providers.formUnion(document.configuration.mcpServers.filter(\.isEnabled).map(\.name))
        }
        remoteProviderOptions = providers.sorted()
    }

    func featureRecord(_ id: String) -> NeoYFeatureRecord? {
        featureRecords.first { $0.id == id }
    }

    func setFeature(_ item: NeoYFeatureCatalogItem, enabled: Bool) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                _ = try await NeoYFeatureManager.shared.setEnabled(item, enabled: enabled)
                await refreshFeatures()
                result = enabled ? "\(item.name) installed and setup started." : "\(item.name) disabled."
            } catch {
                await refreshFeatures()
                result = error.localizedDescription
            }
        }
    }

    func startFeatureSetup(_ item: NeoYFeatureCatalogItem) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                try await NeoYFeatureManager.shared.startSetup(id: item.id)
                await refreshFeatures()
                result = "Started \(item.name) setup in a temporary ChatGPT conversation."
            } catch {
                result = error.localizedDescription
            }
        }
    }

    func uninstallFeature(_ item: NeoYFeatureCatalogItem) {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let provider = featureRecord(item.id)?.provider
                try await NeoYFeatureManager.shared.uninstall(item)
                if let provider { remoteProviders.remove(provider) }
                persistRemoteSettings(restartServer: true)
                await refreshFeatures()
                result = "Uninstalled \(item.name)."
            } catch { result = error.localizedDescription }
        }
    }

    func revokeToken() {
        oauthToken = NeoYCoreAuth.rotateToken()
        NotificationCenter.default.post(name: .neoYDeploymentSettingsChanged, object: nil)
        result = "Previous token revoked. New token issued."
    }

    func testLocal() {
        Task { await probe(localMCPURL, token: nil) }
    }

    func testRemote() {
        guard remoteMCPURL.hasPrefix("https://") else {
            result = "Remote MCP is not connected."
            return
        }
        Task { await probe(remoteMCPURL, token: oauthToken) }
    }

    func refreshPermissions() async {
        permissions = await NeoYPermissionService.snapshot()
    }

    func openPermission(_ kind: NeoYPermissionKind) {
        if NeoYPermissionService.open(kind) {
            result = "Opened System Settings for \(kind.title). Return to Neo and click Refresh after changing access."
        } else {
            result = "Could not open System Settings for \(kind.title)."
        }
    }

    private func persistRemoteSettings(restartServer: Bool = false) {
        do {
            let value = NeoYDeploymentSettingsStore.load()
                .settingRemoteExposure(tools: remoteTools, providers: remoteProviders)
            try NeoYDeploymentSettingsStore.save(value)
            if restartServer {
                NotificationCenter.default.post(name: .neoYDeploymentSettingsChanged, object: nil)
            }
        } catch {
            result = error.localizedDescription
        }
    }

    private func probe(_ urlString: String, token: String?) async {
        isBusy = true
        defer { isBusy = false }
        guard let url = URL(string: urlString) else {
            result = "Invalid MCP URL."
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = #"{"jsonrpc":"2.0","id":"setup-test","method":"tools/list","params":{}}"#.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rpc = object["result"] as? [String: Any],
               let tools = rpc["tools"] as? [[String: Any]] {
                result = "Connected. \(tools.count) tools available."
            } else {
                result = "MCP returned HTTP \(status)."
            }
        } catch {
            result = "Connection failed: \(error.localizedDescription)"
        }
    }

}

struct NeoYSetupView: View {
    @StateObject private var model = NeoYSetupModel()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "n.square.fill").font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Neo").font(.headline)
                        Text("Settings").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 22)

                ForEach(NeoYSetupModel.Tab.allCases) { tab in
                    Button { model.tab = tab } label: {
                        Label(tab.rawValue, systemImage: tabIcon(tab))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 10)
                            .background(model.tab == tab ? Color.accentColor.opacity(0.16) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(18)
            .frame(width: 180)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch model.tab {
                        case .connections: connectionsTab
                        case .features: featuresTab
                        case .deployment: deploymentTab
                        }
                    }
                    .padding(24)
                }
                if !model.result.isEmpty {
                    Divider()
                    Text(model.result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(width: 810, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isBusy)
    }

    private func tabIcon(_ tab: NeoYSetupModel.Tab) -> String {
        switch tab {
        case .connections: "point.3.connected.trianglepath.dotted"
        case .features: "square.grid.2x2"
        case .deployment: "server.rack"
        }
    }

    private var connectionsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Connections", "Neo MCP connection settings.")

            GroupBox("Neo MCP App") {
                VStack(alignment: .leading, spacing: 10) {
                    valueRow("App", value: "Neo")
                    valueRow("Version", value: NeoYCoreRuntime.version)
                    valueRow("Client ID", value: model.oauthClientID)
                    valueRow("Token", value: model.oauthToken)
                    HStack {
                        Text("Keep the token private.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revoke token", role: .destructive) { model.revokeToken() }
                    }
                }
                .padding(8)
            }

            GroupBox("Local MCP Server") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", text: $model.portText)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { model.applyPort() }
                        Button("Apply") { model.applyPort() }
                    }
                    valueRow("Server URL", value: model.localMCPURL)
                    HStack {
                        Spacer()
                        Button("Test") { model.testLocal() }
                    }
                }
                .padding(8)
            }
            remoteConnectionSection
        }
    }

    private var remoteConnectionSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Remote MCP", "Select a mode. Apply to activate.")

            Toggle("Enable remote MCP", isOn: Binding(
                get: { model.remoteEnabled },
                set: { model.setRemoteEnabled($0) }
            ))

            GroupBox("Remote address") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Address", selection: Binding(
                        get: { model.remoteMode },
                        set: { model.setRemoteMode($0) }
                    )) {
                        Text("Temporary").tag(NeoYSetupModel.RemoteMode.temporary)
                        Text("Own domain").tag(NeoYSetupModel.RemoteMode.ownDomain)
                    }
                    .pickerStyle(.segmented)

                    if model.remoteMode == .temporary {
                        Text("No domain is required. The public address can change after Neo or the tunnel restarts, so the MCP app may need to be reconfigured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Hostname, e.g. neoy.qili2.com", text: $model.publicHostname)
                        Text("Use a hostname managed by your Cloudflare account. Once configured, this address remains stable across restarts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text(model.hasPendingRemoteAddress ? "Pending change" : "Applied: \(model.appliedRemoteMode == .temporary ? "Temporary" : "Own Domain")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply") { model.applyRemoteMode() }.disabled(!model.hasPendingRemoteAddress)
                        Button("Test") { model.testRemote() }
                    }
                    if model.remoteEnabled {
                        Divider()
                        valueRow("Remote endpoint", value: model.remoteMCPURL)
                    }
                }
                .padding(8)
            }

        }
    }

    private var featuresTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                heading("Features", "Manage Neo capabilities.")
                Button("Refresh") { Task { await model.refreshMCPTools() } }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.visibleMCPFeatureTools, id: \.self) { tool in
                    featureRow(featureTitle(tool), detail: "MCP") {
                        if NeoYRemoteToolCatalog.nativeOptionalTools[tool] != nil {
                            Toggle("", isOn: Binding(
                                get: { model.nativeEnabledTools.contains(tool) },
                                set: { model.setNativeTool(tool, enabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { !model.disabledDiscoveredTools.contains(tool) },
                                set: { model.setDiscoveredTool(tool, enabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled(model.isBusy)
                        }
                    }
                    Divider()
                }

                ForEach(["wechat-bro", "markcut", "agents-relay"], id: \.self) { skill in
                    featureRow(skill, detail: "Skill") {
                        Toggle("", isOn: Binding(
                            get: { model.optionalSkills.contains(skill) },
                            set: { enabled in
                                if enabled { model.installOptionalSkill(skill) }
                                else { model.removeOptionalSkill(skill) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(model.isBusy)
                    }
                    Divider()
                }

                featureRow("Projects Toolkit", detail: "lalalic/neo · CLI and workflows") {
                    Toggle("", isOn: Binding(
                        get: { model.toolkitEnabled && model.toolkitInstalled },
                        set: { model.setToolkitEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(model.isBusy)
                    if model.toolkitEnabled && model.toolkitInstalled {
                        Button("Update") { model.setupNeoCLI() }.disabled(model.isBusy)
                    }
                }
                if model.toolkitEnabled && model.toolkitInstalled {
                    DisclosureGroup("Projects (\(model.projectNames.count))") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Spacer()
                                Button("Refresh") { model.refreshProjects() }
                            }
                            ForEach(model.projectNames, id: \.self) { name in
                                Text(name)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 6)
                    }
                    .padding(.leading, 28)
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
                }
                Divider()

                ForEach(NeoYFeatureCatalog.all) { item in
                    let record = model.featureRecord(item.id)
                    featureRow(item.name, detail: item.summary) {
                        Toggle("", isOn: Binding(
                            get: { record?.enabled == true },
                            set: { model.setFeature(item, enabled: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        Text(record?.state.rawValue ?? "not installed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let record, record.enabled {
                            if record.state == .setupRequired || record.state == .configuring {
                                Button("Setup") { model.startFeatureSetup(item) }
                            }
                            Button("Uninstall", role: .destructive) { model.uninstallFeature(item) }
                        }
                    }
                    if let error = record?.error, !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
                    }
                    Divider()
                }

            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func featureTitle(_ tool: String) -> String {
        switch tool {
        case "ask_questions": "Ask Questions"
        default: tool.capitalized
        }
    }

    private func featureRow<Actions: View>(
        _ name: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(12)
    }

    private var deploymentTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Deployment", "Cluster nodes.")

            HStack {
                Text("\(model.clusterNodes.count + 1) nodes")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { model.refreshClusterNodes() }
            }

            DisclosureGroup("Add node") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Node name", text: $model.newNodeName)
                    TextField("MCP URL", text: $model.newNodeURL)
                    SecureField("Token (if required)", text: $model.newNodeToken)
                    HStack {
                        Spacer()
                        Button("Add") { model.addClusterNode() }
                            .disabled(model.isBusy || model.newNodeName.isEmpty || model.newNodeURL.isEmpty)
                    }
                }
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Neo Master").font(.body.weight(.medium))
                        Text(NeoYDeploymentSettingsStore.load().localMCPURL)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Local").foregroundStyle(.secondary)
                }
                .padding(12)

                ForEach(model.clusterNodes, id: \.name) { node in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.name).font(.body.weight(.medium))
                            Text(nodeDisplayURL(node.url)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(node.isEnabled ? "Configured" : "Disabled")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) { model.removeClusterNode(node.name) }
                            .disabled(model.isBusy)
                    }
                    .padding(12)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func nodeDisplayURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            return String(raw.split(separator: "?", maxSplits: 1)[0])
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "Invalid node URL"
    }

    private func permissionRow(_ kind: NeoYPermissionKind) -> some View {
        let status = model.permissions.first { $0.kind == kind }
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: status?.state == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(status?.state == .authorized ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                Text("Used by: \(kind.dependentFeatures.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status?.state.rawValue ?? "checking")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if status?.state != .authorized {
                Button("Open Settings") { model.openPermission(kind) }
            }
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            Spacer()
            Button("Copy") { model.copy(value) }
        }
    }
}

extension Notification.Name {
    static let neoYDeploymentSettingsChanged = Notification.Name("NeoY.deploymentSettingsChanged")
}
