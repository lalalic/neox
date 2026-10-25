import SwiftUI

struct RemoteControlView: View {
    @StateObject private var remote = RemoteMCPClient()
    @State private var token = ""
    @State private var address = ""
    @State private var command = ""
    @State private var typing = ""
    @State private var tab = 0
    @State private var showSettings = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showSettings || !remote.connected {
                    configuration
                } else {
                    Picker("Mode", selection: $tab) {
                        Text("Terminal").tag(0)
                        Text("Desktop").tag(1)
                    }
                    .pickerStyle(.segmented).padding()
                    if tab == 0 { terminal } else { desktop }
                }
            }
            .navigationTitle("Neo Remote")
            .toolbar {
                Button(showSettings ? "Done" : "Settings") { showSettings.toggle() }
                    .disabled(!remote.connected)
            }
            .task { address = remote.endpoint }
        }
    }

    private var configuration: some View {
        Form {
            Section("Remote MCP") {
                TextField("https://your-domain/mcp", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(remote.hasCredential ? "Saved token (blank to reuse)" : "Neo token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Connect through the existing Neo HTTPS tunnel. The token is stored in the iPhone Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(remote.busy ? "Connecting…" : "Connect") {
                    do {
                        try remote.saveConfiguration(url: address, token: token)
                        token = ""
                        Task {
                            await remote.connect()
                            if remote.connected { showSettings = false }
                        }
                    } catch { remote.error = error.localizedDescription }
                }
                .disabled(remote.busy)
            }
            if remote.hasCredential {
                Button("Forget token", role: .destructive) {
                    remote.forgetCredential()
                }
            }
            if let error = remote.error {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    private var terminal: some View {
        VStack(spacing: 8) {
            ScrollView {
                Text(remote.terminalOutput.isEmpty ? "Terminal ready" : remote.terminalOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled).padding(12)
            }
            .background(.black)
            HStack {
                Button("Esc") { Task { await remote.sendTerminal("\u{001b}") } }
                Button("Tab") { Task { await remote.sendTerminal("\t") } }
                Button("Ctrl-C") { Task { await remote.sendTerminal("\u{0003}") } }
                Spacer()
                Button("Refresh") { Task { await remote.pollTerminal() } }
            }
            .font(.caption).buttonStyle(.bordered)
            HStack {
                TextField("Command", text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(sendCommand)
                Button("Send", action: sendCommand)
                    .disabled(!remote.isTerminalActive)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            if remote.isTerminalActive {
                Button("Close session", role: .destructive) {
                    Task { await remote.closeTerminal() }
                }
            } else {
                Button("Start Terminal") {
                    Task { await remote.startTerminal() }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(8)
    }

    private func sendCommand() {
        let value = command
        command = ""
        Task { await remote.sendTerminal(value + "\r") }
    }

    private var desktop: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Mac App", selection: $remote.selectedApp) {
                    ForEach(remote.apps, id: \.self) { Text($0).tag($0) }
                }
                Button("Apps") { Task { await remote.listApps() } }
            }
            if let picture = remote.screenshot {
                Image(uiImage: picture)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No screenshot", systemImage: "desktopcomputer")
            }
            HStack {
                Button("Refresh") { Task { await remote.refreshDesktop() } }
                Button("Esc") { Task { await remote.desktopKey("Escape") } }
                Button("Return") { Task { await remote.desktopKey("Return") } }
            }.buttonStyle(.bordered)
            HStack {
                TextField("Type on Mac", text: $typing)
                Button("Type") {
                    let value = typing
                    typing = ""
                    Task { await remote.desktopType(value) }
                }
            }.textFieldStyle(.roundedBorder)
        }.padding().task { await remote.listApps() }
    }
}
