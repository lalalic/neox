import SwiftUI
import WebKitAgent

struct ContentView: View {
    @EnvironmentObject var coordinator: AgentCoordinator
    @Bindable var chatViewModel: ChatViewModel
    @State private var webManager = WebViewManager()
    @State private var showWebView = false
    
    var body: some View {
        ZStack {
            // WebAgentView behind chat — needs real frame for rendering
            WebAgentView(manager: webManager)
                .allowsHitTesting(showWebView)
                .opacity(showWebView ? 1 : 0)
            
            if !showWebView {
                ChatView(viewModel: chatViewModel)
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
}
