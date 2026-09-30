import Foundation
import SwiftUI

@MainActor
final class NeoYSetupModel: ObservableObject {
    enum ServiceMode: String, CaseIterable, Identifiable {
        case local, remote
        var id: String { rawValue }
    }

    enum RemoteMode: String, CaseIterable, Identifiable {
        case dynamic, ownDomain
        var id: String { rawValue }
    }

    @Published var serviceMode: ServiceMode = .local
    @Published var remoteMode: RemoteMode = .dynamic
    @Published var publicHostname = ""
    @Published var oauthClientID = ""
    @Published var oauthToken = ""
    @Published var result = ""
    @Published var isBusy = false

    init() { reload() }

    func reload() {
        let value = NeoYDeploymentSettingsStore.load()
        serviceMode = value.tunnelMode == .off ? .local : .remote
        remoteMode = value.tunnelMode == .named ? .ownDomain : .dynamic
        publicHostname = value.publicHostname
        let credentials = NeoYMCPPluginCredentials.load()
        oauthClientID = credentials.clientID
        oauthToken = credentials.token
    }

    var mcpURL: String {
        let value = NeoYDeploymentSettingsStore.load()
        switch serviceMode {
        case .local:
            return value.localMCPURL
        case .remote:
            return value.publicMCPURL ?? "Not connected"
        }
    }

    var serviceDescription: String {
        switch serviceMode {
        case .local:
            return "Use NeoY directly from this Mac."
        case .remote:
            return remoteMode == .ownDomain
                ? "Use a stable hostname for remote access."
                : "Use a temporary public address. No domain setup required."
        }
    }

    func testService() {
        let url = mcpURL
        guard url.hasPrefix("http") else {
            result = "MCP service is not connected."
            return
        }
        Task { await probe(url) }
    }

    func startTunnel() { Task { await runRuntimeControl("tunnel-start") } }
    func stopTunnel() { Task { await runRuntimeControl("tunnel-stop") } }
    func configureDomain() { Task { await runRuntimeControl("named-create") } }

    func autoApply() {
        do {
            var value = NeoYDeploymentSettingsStore.load()
            value.tunnelMode = serviceMode == .local ? .off : (remoteMode == .ownDomain ? .named : .quick)
            value.publicHostname = publicHostname.trimmingCharacters(in: .whitespacesAndNewlines)
            try NeoYDeploymentSettingsStore.save(value)
            NeoYMCPPluginCredentials.save(clientID: oauthClientID, token: oauthToken)
        } catch {
            result = error.localizedDescription
        }
    }

    func applyServiceMode() {
        autoApply()
        if serviceMode == .remote && remoteMode == .ownDomain && publicHostname.isEmpty {
            return
        }
        if serviceMode == .local {
            Task { await runRuntimeControl("tunnel-stop") }
        } else {
            Task { await runRuntimeControl("tunnel-restart") }
        }
    }

    private func probe(_ urlString: String) async {
        isBusy = true
        defer { isBusy = false }
        guard let url = URL(string: urlString) else {
            result = "Invalid MCP URL"
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"jsonrpc":"2.0","id":"setup-test","method":"tools/list","params":{}}"#.data(using: .utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = status == 200 ? "MCP service is reachable." : "MCP service returned HTTP \(status)."
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
            result = process.terminationStatus == 0 ? (output.isEmpty ? "Done." : output) : "Failed: \(output)"
            reload()
        } catch {
            result = error.localizedDescription
        }
    }
}

struct NeoYSetupView: View {
    @StateObject private var model = NeoYSetupModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                mcpCard
                oauthCard
                if model.serviceMode == .remote {
                    remoteCard
                }
                advancedCard
                if !model.result.isEmpty {
                    resultCard
                }
            }
            .padding(28)
        }
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isBusy)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NeoY")
                .font(.system(size: 28, weight: .semibold))
            Text("Mac agent")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var mcpCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Picker("MCP service", selection: $model.serviceMode) {
                    Text("Local").tag(NeoYSetupModel.ServiceMode.local)
                    Text("Remote").tag(NeoYSetupModel.ServiceMode.remote)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.serviceMode) { _ in model.applyServiceMode() }

                HStack(spacing: 12) {
                    Image(systemName: model.serviceMode == .local ? "desktopcomputer" : "globe")
                        .font(.title2)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.serviceMode == .local ? "Local MCP" : "Remote MCP")
                            .font(.headline)
                        Text(model.serviceDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("MCP endpoint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(model.mcpURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.mcpURL, forType: .string)
                        }
                    }
                }

                Button("Test connection") { model.testService() }
            }
            .padding(8)
        } label: {
            Label("MCP", systemImage: "link")
                .font(.headline)
        }
    }

    private var oauthCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextField("OAuth client ID", text: $model.oauthClientID)
                    .onSubmit { model.autoApply() }
                SecureField("OAuth token", text: $model.oauthToken)
                    .onSubmit { model.autoApply() }
                Text("Used by the MCP plugin connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Label("MCP OAuth", systemImage: "lock.shield")
                .font(.headline)
        }
    }

    private var remoteCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Remote service", selection: $model.remoteMode) {
                    Text("Dynamic").tag(NeoYSetupModel.RemoteMode.dynamic)
                    Text("Own domain").tag(NeoYSetupModel.RemoteMode.ownDomain)
                }
                .pickerStyle(.segmented)
                .onChange(of: model.remoteMode) { _ in model.applyServiceMode() }

                if model.remoteMode == .ownDomain {
                    TextField("Hostname, e.g. neoy.qili2.com", text: $model.publicHostname)
                        .onSubmit { model.autoApply(); model.configureDomain() }
                    Text("Enter the hostname only. NeoY manages the tunnel behind it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Configure domain") { model.autoApply(); model.configureDomain() }
                } else {
                    Text("NeoY will create a temporary public MCP endpoint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Start") { model.startTunnel() }
                    Button("Stop") { model.stopTunnel() }
                }
            }
            .padding(8)
        } label: {
            Label("Remote MCP", systemImage: "network")
                .font(.headline)
        }
    }

    private var advancedCard: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Text("NeoY uses one fixed local service port: \(NeoYDeploymentSettings.defaultPort).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Permissions, startup services, federation, Core tools and diagnostics are configured by the native MCP setup tool.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    private var resultCard: some View {
        Text(model.result)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Notification.Name {
    static let neoYDeploymentSettingsChanged = Notification.Name("NeoY.deploymentSettingsChanged")
}
