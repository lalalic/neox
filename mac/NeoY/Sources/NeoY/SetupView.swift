import Foundation
import SwiftUI

@MainActor
final class NeoYSetupModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case mcp = "MCP"
        case remote = "Remote"
        case tutor = "Tutor"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

    enum RemoteMode: String, CaseIterable, Identifiable {
        case temporary, ownDomain
        var id: String { rawValue }
    }

    @Published var tab: Tab = .mcp
    @Published var portText = String(NeoYDeploymentSettings.defaultPort)
    @Published var remoteEnabled = false
    @Published var remoteMode: RemoteMode = .temporary
    @Published var publicHostname = ""
    @Published var remoteFeatures: Set<NeoYRemoteFeature> = []
    @Published var tutorLearner = ""
    @Published var tutorThreadURL = ""
    @Published private(set) var tutorStatus = "Loading…"
    @Published private(set) var oauthClientID = ""
    @Published private(set) var oauthToken = ""
    @Published var result = ""
    @Published var isBusy = false

    init() { reload() }

    func reload() {
        let value = NeoYDeploymentSettingsStore.load()
        portText = String(value.mcpPort)
        remoteEnabled = value.tunnelMode != .off
        remoteMode = value.tunnelMode == .named ? .ownDomain : .temporary
        publicHostname = value.publicHostname
        remoteFeatures = value.enabledRemoteFeatures
        let credentials = NeoYMCPPluginCredentials.current()
        oauthClientID = credentials.clientID
        oauthToken = credentials.token
        Task { tutorStatus = await NeoYTutorWorkspace.shared.statusJSON() }
    }

    func bindTutorLearner() {
        let learner = tutorLearner
        let threadURL = tutorThreadURL
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                result = try await NeoYTutorWorkspace.shared.bind(learner: learner, threadURL: threadURL)
                tutorStatus = await NeoYTutorWorkspace.shared.statusJSON()
            } catch {
                result = error.localizedDescription
            }
        }
    }

    func unbindTutorLearner() {
        let learner = tutorLearner
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                result = try await NeoYTutorWorkspace.shared.unbind(learner: learner)
                tutorStatus = await NeoYTutorWorkspace.shared.statusJSON()
            } catch {
                result = error.localizedDescription
            }
        }
    }

    func refreshTutor() {
        Task { tutorStatus = await NeoYTutorWorkspace.shared.statusJSON() }
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
            if value.tunnelMode != .off {
                Task { await runRuntimeControl("tunnel-restart") }
            }
            result = "MCP port changed to \(port)."
        } catch {
            result = error.localizedDescription
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        remoteEnabled = enabled
        do {
            var value = NeoYDeploymentSettingsStore.load()
            value.tunnelMode = enabled ? (remoteMode == .ownDomain ? .named : .quick) : .off
            try NeoYDeploymentSettingsStore.save(value)
            if enabled {
                if remoteMode == .ownDomain && publicHostname.isEmpty {
                    result = "Enter a hostname to enable your own domain."
                    return
                }
                Task {
                    if remoteMode == .ownDomain {
                        await runRuntimeControl("named-apply")
                    } else {
                        await runRuntimeControl("tunnel-start")
                    }
                }
            } else {
                Task { await runRuntimeControl("tunnel-stop") }
            }
        } catch {
            result = error.localizedDescription
        }
    }

    func setRemoteMode(_ mode: RemoteMode) {
        remoteMode = mode
        guard remoteEnabled else {
            persistRemoteSettings()
            return
        }
        persistRemoteSettings()
        if mode == .ownDomain && publicHostname.isEmpty {
            result = "Enter a hostname to use your own domain."
            return
        }
        Task {
            if mode == .ownDomain {
                await runRuntimeControl("named-apply")
            } else {
                await runRuntimeControl("tunnel-restart")
            }
        }
    }

    func applyHostname() {
        let hostname = publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostname.isEmpty else {
            result = "Enter a hostname."
            return
        }
        publicHostname = hostname
        remoteEnabled = true
        remoteMode = .ownDomain
        persistRemoteSettings()
        Task { await runRuntimeControl("named-apply") }
    }

    func setRemoteFeature(_ feature: NeoYRemoteFeature, enabled: Bool) {
        if enabled { remoteFeatures.insert(feature) }
        else { remoteFeatures.remove(feature) }
        persistRemoteSettings(restartServer: true)
    }

    func setAllRemoteFeatures(_ enabled: Bool) {
        remoteFeatures = enabled ? Set(NeoYRemoteFeature.allCases) : []
        persistRemoteSettings(restartServer: true)
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

    private func persistRemoteSettings(restartServer: Bool = false) {
        do {
            var value = NeoYDeploymentSettingsStore.load()
            value.tunnelMode = remoteEnabled ? (remoteMode == .ownDomain ? .named : .quick) : .off
            value.publicHostname = publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            value.remoteFeatures = Set(remoteFeatures.map(\.rawValue))
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

    private func runRuntimeControl(_ action: String) async {
        isBusy = true
        defer { isBusy = false }
        guard let script = Bundle.main.url(forResource: "runtime-control", withExtension: "sh") else {
            result = "Runtime control is unavailable."
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, action]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result = process.terminationStatus == 0
                ? (output.isEmpty ? "Done." : output)
                : "Failed: \(output)"
            reload()
        } catch {
            result = error.localizedDescription
        }
    }
}

struct NeoYSetupView: View {
    @StateObject private var model = NeoYSetupModel()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(NeoYSetupModel.Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Divider().padding(.top, 16)

            ScrollView {
                Group {
                    switch model.tab {
                    case .mcp: mcpTab
                    case .remote: remoteTab
                    case .tutor: tutorTab
                    case .advanced: advancedTab
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
                    .padding(16)
            }
        }
        .frame(width: 660, height: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isBusy)
    }

    private var mcpTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("MCP", "Local service and the values needed to create an MCP app.")

            GroupBox("Local service") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", text: $model.portText)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { model.applyPort() }
                        Button("Apply") { model.applyPort() }
                    }
                    Divider()
                    valueRow("Endpoint", value: model.localMCPURL)
                    HStack {
                        Button("Test local") { model.testLocal() }
                        Spacer()
                        Text("All enabled features are available locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox("MCP app configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    valueRow("Client ID", value: model.oauthClientID)
                    valueRow("Token", value: model.oauthToken)
                    HStack(alignment: .top) {
                        Text("Use these values when creating the MCP app connection. The token is a secret.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Revoke token", role: .destructive) { model.revokeToken() }
                    }
                }
                .padding(8)
            }
        }
    }

    private var remoteTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Remote", "Expose only the features you choose.")

            Toggle("Enable remote MCP", isOn: Binding(
                get: { model.remoteEnabled },
                set: { model.setRemoteEnabled($0) }
            ))

            GroupBox("Address") {
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
                        Text("No domain is required. The public address can change after NeoY or the tunnel restarts, so the MCP app may need to be reconfigured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Hostname, e.g. neoy.qili2.com", text: $model.publicHostname)
                            .onSubmit { model.applyHostname() }
                        Text("Use a hostname managed by your Cloudflare account. Once configured, this address remains stable across restarts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Apply hostname") { model.applyHostname() }
                    }

                    if model.remoteEnabled {
                        Divider()
                        valueRow("Remote endpoint", value: model.remoteMCPURL)
                        Button("Test remote") { model.testRemote() }
                    }
                }
                .padding(8)
            }

            GroupBox("Remote features") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Local access is unchanged. These switches only control remote access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("All") { model.setAllRemoteFeatures(true) }
                        Button("None") { model.setAllRemoteFeatures(false) }
                    }
                    Divider()
                    ForEach(NeoYRemoteFeature.allCases) { feature in
                        Toggle(feature.title, isOn: Binding(
                            get: { model.remoteFeatures.contains(feature) },
                            set: { model.setRemoteFeature(feature, enabled: $0) }
                        ))
                    }
                }
                .padding(8)
            }
        }
    }

    private var tutorTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Tutor", "Fixed Family Tutor workspace backed by persistent ChatGPT threads.")

            GroupBox("ChatGPT platform") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ChatGPT page mechanics come from browser-platforms. NeoY stores learner/thread bindings only; transcripts remain in ChatGPT.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.tutorStatus)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(8)
                    Button("Refresh") { model.refreshTutor() }
                }
                .padding(8)
            }

            GroupBox("Learner binding") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Learner id, e.g. maggie", text: $model.tutorLearner)
                    TextField("Existing ChatGPT thread URL", text: $model.tutorThreadURL)
                    HStack {
                        Button("Bind") { model.bindTutorLearner() }
                        Button("Unbind", role: .destructive) { model.unbindTutorLearner() }
                        Spacer()
                    }
                    Text("A learner keeps one durable thread binding. If the browser target disappears, the ChatGPT platform recovers from the saved thread URL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Advanced", "Runtime details and operational settings.")

            GroupBox("Runtime") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("NeoY uses one MCP listener. Agent handoff, MCP and health routes share the configured port.")
                    Text("Remote transport is provided by Cloudflare when enabled.")
                    Text("Permissions, startup services, diagnostics and MCP federation remain available through neoy.setup.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
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
