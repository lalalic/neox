import SwiftUI
import WebKitAgent
import CopilotChat

struct ContentView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @State private var webManager = WebViewManager()
    @State private var showWebView = false
    @State private var showSettings = false
    
    var body: some View {
        ZStack {
            // WebAgentView behind chat — needs real frame for rendering
            WebAgentView(manager: webManager)
                .allowsHitTesting(showWebView)
                .opacity(showWebView ? 1 : 0)
            
            if !showWebView {
                if let chatVM = coordinator.chatViewModel {
                    NavigationStack {
                        CopilotChat.ChatView(viewModel: chatVM, inputModes: coordinator.chatInputModes)
                            .navigationTitle("Neo")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: { showWebView.toggle() }) {
                                        Image(systemName: showWebView ? "bubble.left.fill" : "globe")
                                    }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(action: { showSettings = true }) {
                                        Image(systemName: "gearshape.fill")
                                            .foregroundStyle(statusColor)
                                    }
                                }
                            }
                    }
                } else {
                    ProgressView("Initializing...")
                }
            }
        }
        .onAppear {
            coordinator.setupWebKitAgent(manager: webManager)
        }
        .sheet(isPresented: $showSettings) {
            RelaySettingsView()
                .environmentObject(coordinator)
        }
    }
    
    private var statusColor: Color {
        let setup = AppAgentSetup.shared
        return (setup.isRunning || setup.bridgeState == "connected") ? .green : .gray
    }
}

// MARK: - Relay Settings View

struct RelaySettingsView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Relay Server") {
                    Toggle("Use local relay server", isOn: $coordinator.useLocalRelay)

                    TextField("http://10.0.0.111:8765", text: $coordinator.localRelayURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(!coordinator.useLocalRelay)

                    if !coordinator.useLocalRelay {
                        Text("relay.ai.qili2.com")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Dev Server") {
                    Toggle("Enable dev server bridge", isOn: $coordinator.useDevServer)

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("9223", value: $coordinator.devServerPort, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .keyboardType(.numberPad)
                            .disabled(!coordinator.useDevServer)
                    }
                }

                Section("Chat Input") {
                    Toggle("Text", isOn: $coordinator.enableTextInput)
                    Toggle("Speech", isOn: $coordinator.enableSpeechInput)
                    Toggle("Attachment", isOn: $coordinator.enableAttachmentInput)
                }
                
                Section {
                    Button("Apply & Reconnect") {
                        applySettings()
                        coordinator.reconnect()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func applySettings() {
        if coordinator.devServerPort <= 0 {
            coordinator.devServerPort = 9223
        }

        coordinator.applyRelaySelection()
        coordinator.saveRelaySettings()

        let setup = AppAgentSetup.shared
        if coordinator.useDevServer {
            setup.connectBridge(url: "ws://10.0.0.101:\(coordinator.devServerPort)/ws")
        } else {
            setup.disconnectBridge()
        }
    }
}
