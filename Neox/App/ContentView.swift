import SwiftUI
import WebKitAgent
import CopilotChat
import CopilotSDK

struct ContentView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @State private var webManager = WebViewManager()
    @State private var showWebView = false
    @State private var showSettings = false
    @State private var showProjects = false
    @State private var showModelPicker = false
    @State private var currentProject: String? = nil
    
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
                            .navigationTitle(currentProject ?? "Neo")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    HStack(spacing: 4) {
                                        ProjectBadgeView(
                                            currentProject: currentProject,
                                            action: { showProjects = true }
                                        )
                                        Button(action: { showWebView.toggle() }) {
                                            Image(systemName: "globe")
                                        }
                                    }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    HStack(spacing: 8) {
                                        ModelBadgeView(modelId: coordinator.selectedModel) {
                                            showModelPicker = true
                                        }
                                        UsageBadgeView(tracker: chatVM.usageTracker)
                                        Button(action: { showSettings = true }) {
                                            Image(systemName: "gearshape.fill")
                                                .foregroundStyle(statusColor)
                                        }
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
        .sheet(isPresented: $showProjects) {
            ProjectsView(
                rootURL: coordinator.workspaceRootURL,
                currentProject: currentProject,
                onSelect: { project in
                    currentProject = project?.name
                    if let chatVM = coordinator.chatViewModel {
                        chatVM.projectScope = project?.name
                    }
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            RelaySettingsView()
                .environmentObject(coordinator)
        }
        .sheet(isPresented: $showModelPicker) {
            NavigationStack {
                ModelPickerView(
                    selectedModelId: $coordinator.selectedModel,
                    onModelChanged: { newModel in
                        coordinator.saveRelaySettings()
                        coordinator.reconnect()
                        showModelPicker = false
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showModelPicker = false }
                    }
                }
            }
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

                Section("Agent Profile") {
                    NavigationLink("Edit main.agent.md") {
                        MarkdownH1FileEditorView(
                            fileURL: coordinator.mainAgentFileURL,
                            navigationTitleText: "Edit main.agent.md",
                            loadingText: "Loading main.agent.md...",
                            availableTools: Array(Set(coordinator.allTools.map(\.name))).sorted()
                        )
                    }
                    NavigationLink {
                        ModelPickerView(
                            selectedModelId: $coordinator.selectedModel,
                            onModelChanged: { _ in
                                coordinator.saveRelaySettings()
                            }
                        )
                    } label: {
                        HStack {
                            Text("Model")
                            Spacer()
                            Text(ModelCatalog.model(for: coordinator.selectedModel)?.name ?? coordinator.selectedModel)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Plans") {
                    NavigationLink {
                        PlanManagerView(
                            store: coordinator.chatViewModel?.planStore ?? PlanStore(),
                            onRunPlan: { plan in
                                if let chatVM = coordinator.chatViewModel {
                                    Task {
                                        await chatVM.runPlan(plan)
                                    }
                                }
                            }
                        )
                    } label: {
                        Label("Manage Plans", systemImage: "calendar.badge.clock")
                    }
                }

                Section("Credits") {
                    if let chatVM = coordinator.chatViewModel,
                       let pm = coordinator.paymentManager {
                        NavigationLink {
                            PaymentView(paymentManager: pm, usageTracker: chatVM.usageTracker)
                        } label: {
                            HStack {
                                Label("Buy Credits", systemImage: "creditcard.fill")
                                Spacer()
                                Text(String(format: "$%.2f", chatVM.usageTracker.balance))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                Section("Workspace") {
                    NavigationLink {
                        FileExplorerView(
                            rootURL: coordinator.workspaceRootURL,
                            title: "Workspace"
                        )
                    } label: {
                        Label("File Explorer", systemImage: "folder")
                    }
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
