import Foundation
import SwiftUI

@MainActor
final class NeoYSetupModel: ObservableObject {
    @Published var portText = ""
    @Published var tunnelMode: NeoYTunnelMode = .off
    @Published var tunnelName = ""
    @Published var publicHostname = ""
    @Published var pluginID = ""
    @Published var result = ""
    @Published var isBusy = false

    init() { reload() }

    func reload() {
        let value = NeoYDeploymentSettingsStore.load()
        portText = String(value.mcpPort)
        tunnelMode = value.tunnelMode
        tunnelName = value.tunnelName
        publicHostname = value.publicHostname
        pluginID = value.chatGPTPluginID
    }

    func saveAndApply() {
        guard let port = UInt16(portText), port > 0 else { result = "Invalid port"; return }
        let value = NeoYDeploymentSettings(
            mcpPort: port,
            tunnelMode: tunnelMode,
            tunnelName: tunnelName,
            publicHostname: publicHostname,
            chatGPTPluginID: pluginID
        )
        do {
            try NeoYDeploymentSettingsStore.save(value)
            result = "Saved. Restarting MCP listener and tunnel…"
            NotificationCenter.default.post(name: .neoYDeploymentSettingsChanged, object: nil)
            Task { await runRuntimeControl("tunnel-restart") }
        } catch {
            result = error.localizedDescription
        }
    }

    func testLocal() { Task { await probe(NeoYDeploymentSettingsStore.load().localMCPURL) } }

    func testPublic() {
        guard let url = NeoYDeploymentSettingsStore.load().publicMCPURL else {
            result = "No public MCP URL yet."
            return
        }
        Task { await probe(url) }
    }

    func startTunnel() { Task { await runRuntimeControl("tunnel-start") } }
    func stopTunnel() { Task { await runRuntimeControl("tunnel-stop") } }
    func createNamedTunnel() { Task { await runRuntimeControl("named-create") } }

    private func probe(_ urlString: String) async {
        isBusy = true
        defer { isBusy = false }
        guard let url = URL(string: urlString) else { result = "Invalid URL"; return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"jsonrpc":"2.0","id":"setup-test","method":"tools/list","params":{}}"#.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = "HTTP \(status) — \(data.count) bytes — \(urlString)"
        } catch {
            result = "Test failed: \(error.localizedDescription)"
        }
    }

    private func runRuntimeControl(_ action: String) async {
        isBusy = true
        defer { isBusy = false }
        guard let script = Bundle.main.url(forResource: "runtime-control", withExtension: "sh") else {
            result = "Runtime control script is not bundled."
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
            result = process.terminationStatus == 0 ? (output.isEmpty ? "OK" : output) : "Failed: \(output)"
            reload()
        } catch {
            result = error.localizedDescription
        }
    }
}

struct NeoYSetupView: View {
    @StateObject private var model = NeoYSetupModel()

    var body: some View {
        Form {
            Section("MCP") {
                HStack {
                    Text("Local port")
                    TextField("9224", text: $model.portText).frame(width: 100)
                    Button("Test local") { model.testLocal() }
                }
                Text("Local URL: http://127.0.0.1:\(model.portText)/mcp")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            Section("Cloudflare tunnel") {
                Picker("Mode", selection: $model.tunnelMode) {
                    Text("Off").tag(NeoYTunnelMode.off)
                    Text("Temporary").tag(NeoYTunnelMode.quick)
                    Text("Own domain").tag(NeoYTunnelMode.named)
                }
                .pickerStyle(.segmented)

                if model.tunnelMode == .named {
                    TextField("Tunnel name", text: $model.tunnelName)
                    TextField("Hostname, e.g. neoy.example.com", text: $model.publicHostname)
                    Button("Create / route named tunnel") { model.createNamedTunnel() }
                }

                HStack {
                    Button("Start") { model.startTunnel() }
                    Button("Stop") { model.stopTunnel() }
                    Button("Test public") { model.testPublic() }
                }

                if let url = NeoYDeploymentSettingsStore.load().publicMCPURL {
                    Text("Public URL: \(url)").font(.caption).textSelection(.enabled)
                }
            }

            Section("ChatGPT plugin") {
                TextField("plugin id (optional)", text: $model.pluginID)
                Text("The plugin points at the public MCP URL. NeoY tools are discovered dynamically through tools/list.")
                    .font(.caption)
            }

            HStack {
                Button("Reload") { model.reload() }
                Spacer()
                Button("Save & Apply") { model.saveAndApply() }
                    .keyboardShortcut(.defaultAction)
            }

            if !model.result.isEmpty {
                Text(model.result).font(.caption).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 620, height: 500)
        .disabled(model.isBusy)
    }
}

extension Notification.Name {
    static let neoYDeploymentSettingsChanged = Notification.Name("NeoY.deploymentSettingsChanged")
}
