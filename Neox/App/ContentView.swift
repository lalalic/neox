import SwiftUI
import SafariServices
import WebKitAgent
import CopilotChat
import CopilotSDK

struct ContentView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @StateObject private var webManager = WebViewManager()
    @State private var showWebView = false
    @State private var showSettings = false
    @State private var showProjects = false
    @State private var showModelPicker = false
    @State private var currentProject: String? = nil
    @State private var currentProjectDisplay: String? = nil
    @State private var stripeCheckoutURL: URL? = nil
    @State private var showCreditToast = false
    @State private var creditToastText = ""
    @State private var showContactSelector = false
    @State private var showQRLogin = false
    @State private var qrLoginDismissed = false  // Prevent re-show after user dismissal
    
    var body: some View {
        ZStack {
            // WebAgentView behind chat — needs real frame for rendering
            if showWebView {
                WebAgentView(manager: webManager)
                    .overlay(alignment: .top) {
                        HStack {
                            Button(action: { showWebView = false }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(webManager.pageTitle.isEmpty ? (webManager.currentURL?.host ?? "Browser") : webManager.pageTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button(action: { webManager.webView.reload() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                    }
                }
            
            if !showWebView {
                if let chatVM = coordinator.chatViewModel {
                    NavigationStack {
                        CopilotChat.ChatView(viewModel: chatVM, inputModes: coordinator.chatInputModes)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    HStack(spacing: 0) {
                                        Button(action: { showProjects = true }) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "folder.fill")
                                                    .foregroundStyle(.primary)
                                                if let name = currentProject {
                                                    Text(name)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.tail)
                                                        .frame(maxWidth: 60)
                                                }
                                            }
                                            .frame(height: 44)
                                            .contentShape(Rectangle())
                                        }
                                        .accessibilityLabel("Projects")
                                    }
                                }
                                ToolbarItem(placement: .principal) {
                                    HStack(spacing: 4) {
                                        ConnectionTitleView(
                                            title: "Neo",
                                            viewModel: chatVM
                                        )
                                        if coordinator.activeWatcherCount > 0 {
                                            WatcherBadge(count: coordinator.activeWatcherCount)
                                        }
                                    }
                                }
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(action: { showSettings = true }) {
                                        Image(systemName: "gearshape.fill")
                                            .foregroundStyle(.primary)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                }
                            }
                    }
                } else {
                    ProgressView("Initializing...")
                }
            }

            if showCreditToast {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(creditToastText)
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.green.opacity(0.95), in: Capsule())
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
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
                    currentProjectDisplay = project?.displayName
                    if let chatVM = coordinator.chatViewModel {
                        chatVM.projectScope = project?.name
                        if let pid = project?.id {
                            if let steer = coordinator.buildProjectSwitchSteer(projectId: pid) {
                                Task { await chatVM.sendHidden(steer) }
                            }
                        } else {
                            Task { await chatVM.sendHidden("User left project context. No specific project is selected.") }
                        }
                    }
                },
                onDelete: { project in
                    if let repo = project.repo {
                        Task {
                            await coordinator.chatViewModel?.archiveRepo(repo)
                        }
                    }
                },
                weChatService: coordinator.channelType == "wechat" ? coordinator.weChatService : nil,
                discordService: coordinator.channelType == "discord" ? coordinator.discordService : nil,
                onSessionReset: { projectId in
                    coordinator.destroyProjectSession(projectId: projectId)
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            RelaySettingsView(weChatService: coordinator.weChatService)
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
        .sheet(item: $stripeCheckoutURL) { url in
            SafariView(url: url)
                .ignoresSafeArea()
                .onDisappear {
                    // Clear the URL in ChatViewModel so fallback doesn't trigger
                    coordinator.chatViewModel?.stripeCheckoutURL = nil
                }
        }
        .sheet(isPresented: $showContactSelector) {
            ContactSelectorView(
                weChatService: coordinator.weChatService,
                project: currentProject
            )
        }
        .sheet(isPresented: $showQRLogin, onDismiss: {
            qrLoginDismissed = true
        }) {
            WeChatQRLoginView(weChatService: coordinator.weChatService)
        }
        .onReceive(coordinator.weChatService.$channelState) { newState in
            if newState == .qrReady && !showQRLogin && !qrLoginDismissed {
                showQRLogin = true
            } else if newState == .ready || newState == .dead || newState == .disconnected {
                showQRLogin = false
                qrLoginDismissed = false  // Reset on channel restart
            } else if newState == .loading {
                qrLoginDismissed = false  // Reset when loading new QR
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stripeCheckoutRequested)) { note in
            if let url = note.object as? URL {
                stripeCheckoutURL = url
                // Signal to ChatViewModel that SFSafariVC consumed the URL
                coordinator.chatViewModel?.stripeCheckoutURL = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stripeCreditsGranted)) { note in
            // Auto-dismiss checkout if still open
            stripeCheckoutURL = nil

            let credits = (note.userInfo?["credits"] as? Double) ?? 0
            if credits > 0 {
                creditToastText = String(format: "Payment verified: +$%.2f credits", credits)
            } else {
                creditToastText = "Payment verified and credits added"
            }

            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                showCreditToast = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.2)) {
                    showCreditToast = false
                }
            }
        }
    }
    
    private var statusColor: Color {
        let setup = AppAgentSetup.shared
        return (setup.isRunning || setup.bridgeState == "connected") ? .green : .gray
    }
}

// MARK: - Connection Title (now in CopilotChat.ConnectionTitleView)

// MARK: - Relay Settings View

struct RelaySettingsView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @ObservedObject var weChatService: WeChatService
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Agent Profile") {
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
                    NavigationLink("Agent Profile") {
                        MarkdownH1FileEditorView(
                            fileURL: coordinator.mainAgentFileURL,
                            navigationTitleText: "Edit main.agent.md",
                            loadingText: "Loading main.agent.md...",
                            availableTools: Array(Set(coordinator.allRegisteredTools.map(\.name))).sorted()
                        )
                    }
                    HStack {
                        Text("Device ID")
                        Spacer()
                        Text(coordinator.neoxUserId)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

                Section("Chat Input") {
                    Toggle("Text", isOn: $coordinator.enableTextInput)
                    Toggle("Speech", isOn: $coordinator.enableSpeechInput)
                    Toggle("Attachment", isOn: $coordinator.enableAttachmentInput)
                }

                Section("Chat Notifications") {
                    Toggle("Usage/Cost", isOn: $coordinator.showUsageInChat)
                    Toggle("Agent Progress", isOn: $coordinator.showProgressInChat)
                    Toggle("Build Status", isOn: $coordinator.showBuildInChat)
                }

                // MARK: Channel
                Section("Channel") {
                    Toggle("WeChat", isOn: Binding(
                        get: { weChatService.config.enabled },
                        set: { newValue in
                            if newValue {
                                coordinator.channelType = "wechat"
                                weChatService.enable()
                            } else {
                                if coordinator.channelType == "wechat" {
                                    coordinator.channelType = ""
                                }
                                weChatService.disable()
                            }
                        }
                    ))

                    Toggle("Discord", isOn: Binding(
                        get: { coordinator.channelType == "discord" },
                        set: { newValue in
                            if newValue {
                                coordinator.channelType = "discord"
                            } else {
                                coordinator.channelType = ""
                            }
                        }
                    ))

                    if coordinator.channelType == "discord" {
                        HStack {
                            Text("Status")
                            Spacer()
                            if coordinator.discordService.isConnected {
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            } else {
                                Label("Disconnected", systemImage: "circle")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }

                        TextField("Server ID", text: Binding(
                            get: { coordinator.discordService.guildId },
                            set: { coordinator.discordService.guildId = $0 }
                        ))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.numberPad)

                        Button {
                            let botClientId = "1489316184578068755"
                            if let url = URL(string: "https://discord.com/oauth2/authorize?client_id=\(botClientId)&permissions=3072&scope=bot") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Invite Bot to Server", systemImage: "link.badge.plus")
                        }
                    }
                }

                #if DEBUG
                Section("Developer") {
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
                #endif

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
                    Button("Done") {
                        applySettings()
                        coordinator.reconnect()
                        dismiss()
                    }
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

// MARK: - URL+Identifiable for .sheet(item:)

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Stripe Checkout Notification

extension Notification.Name {
    static let stripeCheckoutRequested = Notification.Name("stripeCheckoutRequested")
    static let stripeCreditsGranted = Notification.Name("stripeCreditsGranted")
}

// MARK: - SFSafariViewController SwiftUI Wrapper

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = .systemBlue
        return vc
    }
    
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
