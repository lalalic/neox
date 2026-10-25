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
    @State private var commandsOpened = false

    var body: some View {
        NavigationStack {
            ZStack {
                if !remote.connected && !showSettings {
                    VStack(spacing: 14) {
                        if remote.busy || remote.error == nil {
                            ProgressView("Connecting to your Mac…")
                        } else {
                            Text("Could not connect to your Mac.")
                            Button("Try again") { Task { await remote.connect() } }
                            if let error = remote.error {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if remote.connected {
                    VStack(spacing: 0) {
                        Picker("Choose view", selection: $tab) {
                        Text("Desktop").tag(0)
                        Text("Commands").tag(1)
                    }
                    .pickerStyle(.segmented).padding()
                        ZStack {
                            VNCViewerView(remote: remote)
                            .id(remote.endpoint)
                            .opacity(tab == 0 ? 1 : 0)
                            .allowsHitTesting(tab == 0 && !showSettings)
                        if commandsOpened {
                            terminal
                                .opacity(tab == 1 ? 1 : 0)
                                .allowsHitTesting(tab == 1 && !showSettings)
                        }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if showSettings { configuration }
            }
            .navigationTitle(remote.selectedMasterName)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings.toggle() } label: {
                        Image(systemName: showSettings ? "checkmark" : "gearshape")
                    }
                    .accessibilityLabel(showSettings ? "Done" : "Settings")
                }
            }
            .task {
                syncSelectedMaster()
                if !remote.hasCredential || !remote.hasConfiguredAddress ||
                   MacScreenCredentials.load(for: remote.endpoint) == nil {
                    showSettings = true
                } else {
                    await remote.connect()
                }
            }
            .onChange(of: bridge.preferredBridge) { _, _ in
                Task { await remote.closeTerminal() }
                remote.disconnect()
                commandsOpened = false
                syncSelectedMaster()
                if !remote.hasCredential || MacScreenCredentials.load(for: remote.endpoint) == nil {
                    showSettings = true
                }
            }
            .onChange(of: bridge.discoveredBridges) { _, _ in
                // Keep an established remote session stable through Bonjour refreshes.
                guard !remote.connected else { return }
                syncSelectedMaster()
                if !remote.hasCredential { showSettings = true }
            }
            .onChange(of: showSettings) { _, showing in
                if !showing && remote.hasCredential && !remote.connected {
                    Task { await remote.connect() }
                }
            }
            .onChange(of: tab) { _, newValue in
                if newValue == 1 { commandsOpened = true }
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
                Text(!remote.hasTerminalTool ? "Commands are not available on this Mac." :
                     remote.terminalOutput.isEmpty ?
                     (remote.busy ? "Connecting to your Mac…" : "Ready for commands") :
                     remote.terminalOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled).padding(12)
            }
            .background(.black)
            .task {
                if !remote.isTerminalActive && remote.hasTerminalTool {
                    await remote.startTerminal()
                }
            }
            HStack {
                Button("Esc") { Task { await remote.sendTerminal("\u{001b}") } }
                Button("Tab") { Task { await remote.sendTerminal("\t") } }
                Button("Ctrl-C") { Task { await remote.sendTerminal("\u{0003}") } }
                Spacer()
                Button("Update") { Task { await remote.pollTerminal() } }
            }
            .font(.caption).buttonStyle(.bordered)
            .padding(.horizontal, 12)
            HStack {
                TextField("Type a command", text: $command)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(sendCommand)
                Button(action: sendCommand) {
                    Image(systemName: "return")
                }
                .accessibilityLabel("Send command")
                .disabled(!remote.isTerminalActive)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            if let error = remote.error {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("Try again") { Task { await remote.startTerminal() } }
                    .disabled(remote.busy)
            }
        }
    }

    private func sendCommand() {
        let value = command
        command = ""
        Task { await remote.sendTerminal(value + "\r") }
    }
}
