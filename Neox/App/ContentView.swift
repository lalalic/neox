import SwiftUI
import WebKitAgent
import CopilotChat

struct ContentView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @State private var webManager = WebViewManager()
    @State private var showWebView = false
    
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
