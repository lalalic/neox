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
                        CopilotChat.ChatView(viewModel: chatVM, inputModes: .all)
                            .navigationTitle("Neox")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: { showSettings = true }) {
                                        Image(systemName: "gear")
                                    }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    statusIndicator
                                }
                            }
                    }
                } else {
                    ProgressView("Initializing...")
                }
            }
            
            // Toggle button
            VStack {
                HStack {
                    Spacer()
                    Button(action: { showWebView.toggle() }) {
                        Image(systemName: showWebView ? "bubble.left.fill" : "globe")
                            .font(.title2)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
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
    
    private var statusIndicator: some View {
        HStack(spacing: 4) {
            let setup = AppAgentSetup.shared
            if let err = setup.startError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else {
                Text(setup.bridgeState != "off" ? "bridge:\(setup.bridgeState)" : setup.serverState)
                    .font(.caption2)
                    .foregroundStyle(setup.isRunning || setup.bridgeState == "connected" ? .green : .secondary)
            }
            Circle()
                .fill(setup.isRunning || setup.bridgeState == "connected" ? Color.green : Color.red)
                .frame(width: 8, height: 8)
        }
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
                    TextField("Host", text: $coordinator.relayHost)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $coordinator.relayPort, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .keyboardType(.numberPad)
                    }
                }
                
                Section {
                    Button("Use Local Dev Server") {
                        coordinator.relayHost = "10.0.0.111"
                        coordinator.relayPort = 8765
                    }
                    
                    Button("Use Production Server") {
                        coordinator.relayHost = "relay.ai.qili2.com"
                        coordinator.relayPort = 443
                    }
                }
                
                Section {
                    Button("Reconnect") {
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
}
