import SwiftUI

/// The master selected on the home screen owns both Desktop and Commands.
struct RemoteControlView: View {
    @EnvironmentObject private var bridge: ServerController
    @StateObject private var remote = RemoteMCPClient()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var address = ""
    @State private var account = ""
    @State private var password = ""
    @State private var command = ""
    @State private var tab = 0
    @State private var showSettings = false
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showSettings || !remote.connected {
                    configuration
                } else {
                    Picker("Choose view", selection: $tab) {
                        Text("Desktop").tag(0)
                        Text("Commands").tag(1)
                    }
                    .pickerStyle(.segmented).padding()
                    if tab == 0 { VNCViewerView(remote: remote) } else { terminal }
                }
            }
            .navigationTitle(remote.selectedMasterName)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if remote.connected {
                        Button(showSettings ? "Done" : "Settings") { showSettings.toggle() }
                    }
                }
            }
            .task {
                syncSelectedMaster()
                if remote.hasCredential && remote.hasConfiguredAddress {
                    await remote.connect()
                } else {
                    showSettings = true
                }
            }
            .onChange(of: bridge.preferredBridge) { _, _ in
                Task { await remote.closeTerminal() }
                syncSelectedMaster()
                if !remote.hasCredential { showSettings = true }
            }
            .onChange(of: bridge.discoveredBridges) { _, _ in
                syncSelectedMaster()
                if !remote.hasCredential { showSettings = true }
            }
            .onChange(of: showSettings) { _, showing in
                if showing { Task { await remote.closeTerminal() } }
            }
            .onChange(of: tab) { _, newValue in
                if newValue == 0 { Task { await remote.closeTerminal() } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { Task { await remote.closeTerminal() } }
            }
            .onDisappear { Task { await remote.closeTerminal() } }
        }
    }

    private func syncSelectedMaster() {
        let selected = bridge.discoveredBridges.first { $0.name == bridge.preferredBridge }
            ?? (bridge.preferredBridge == nil ? bridge.discoveredBridges.first : nil)
        if let selected {
            remote.selectMaster(name: selected.name, advertisedURL: selected.remoteURL)
        } else if let preferred = bridge.preferredBridge {
            remote.selectMaster(name: preferred, advertisedURL: nil)
        }
        address = remote.endpoint
        if let saved = MacScreenCredentials.load(for: remote.endpoint) {
            account = saved.username
            password = ""
        } else {
            account = ""
            password = ""
        }
    }

    private var configuration: some View {
        Form {
            Section("Neo Master") {
                Label(remote.selectedMasterName, systemImage: "desktopcomputer")
                Text("Desktop and Commands use this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connect") {
                SecureField(remote.hasCredential ? "Access code saved" : "Access code", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("The access code is stored on this iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mac sign-in") {
                TextField("Mac account", text: $account)
                    .textInputAutocapitalization(.never)
                SecureField("Mac password", text: $password)
                Text("Leave the password blank to keep the saved one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(remote.busy ? "Connecting…" : "Save and connect") {
                    do {
                        try remote.saveConfiguration(url: address, token: token)
                        if !account.isEmpty && !password.isEmpty {
                            try MacScreenCredentials.save(username: account, password: password,
                                                          for: remote.endpoint)
                        }
                        token = ""
                        password = ""
                        Task {
                            await remote.connect()
                            if remote.connected { showSettings = false }
                        }
                    } catch {
                        remote.error = error.localizedDescription
                    }
                }
                .disabled(remote.busy)
            }
            Section {
                DisclosureGroup("Connection details", isExpanded: $showAdvanced) {
                    TextField("Secure address", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Only needed when your Mac cannot be found automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if remote.hasCredential {
                    Button("Forget this Mac", role: .destructive) {
                        remote.forgetCredential()
                    }
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
                Text(remote.terminalOutput.isEmpty ? "Ready" : remote.terminalOutput)
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
                Button("Update") { Task { await remote.pollTerminal() } }
            }
            .font(.caption).buttonStyle(.bordered)
            HStack {
                TextField("Type a command", text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(sendCommand)
                Button("Send", action: sendCommand)
                    .disabled(!remote.isTerminalActive)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            if remote.isTerminalActive {
                Button("Finish", role: .destructive) {
                    Task { await remote.closeTerminal() }
                }
            } else {
                Button("Start commands") { Task { await remote.startTerminal() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!remote.hasTerminalTool)
            }
        }.padding(8)
    }

    private func sendCommand() {
        let value = command
        command = ""
        Task { await remote.sendTerminal(value + "\r") }
    }
}
