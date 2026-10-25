import SwiftUI

struct RemoteControlView: View {
    @StateObject private var remote = RemoteMCPClient()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var address = ""
    @State private var command = ""
    @State private var tab = 0
    @State private var showSettings = false

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
             .navigationTitle("My Mac")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showSettings ? "Done" : "Macs") { showSettings.toggle() }
                        .disabled(!remote.connected)
                }
            }
            .task {
                address = remote.endpoint
                if remote.hasCredential && !remote.endpoint.isEmpty {
                    await remote.connect()
                } else {
                    showSettings = true
                }
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
            .onDisappear {
                Task { await remote.closeTerminal() }
            }
        }
    }

    private var configuration: some View {
        Form {
            if !remote.savedMacs.isEmpty {
                Section("Your Macs") {
                    ForEach(remote.savedMacs) { mac in
                        Button {
                            remote.useSavedMac(mac)
                            address = mac.url
                            token = ""
                            Task {
                                await remote.connect()
                                if remote.connected { showSettings = false }
                            }
                        } label: {
                            Label(mac.name, systemImage: "desktopcomputer")
                        }
                    }
                }
            }
            Section("Add a Mac") {
                TextField("Mac address", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(remote.hasCredential ? "Saved passcode" : "Access code", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("Enter the address and access code once. Your iPhone will remember this Mac.")
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
                Button("Remove saved Mac", role: .destructive) {
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
                Button("Start commands") {
                    Task { await remote.startTerminal() }
                }.buttonStyle(.borderedProminent)
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
