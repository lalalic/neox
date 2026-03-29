import SwiftUI

@main
struct NeoxApp: App {
    @StateObject private var coordinator = AgentCoordinator()
    @State private var chatViewModel = ChatViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView(chatViewModel: chatViewModel)
                .environmentObject(coordinator)
                .onAppear {
                    coordinator.wireChat(chatViewModel)
                    startAppAgent(chatViewModel: chatViewModel, coordinator: coordinator)
                }
        }
    }
    
    private func startAppAgent(chatViewModel: ChatViewModel, coordinator: AgentCoordinator) {
        let setup = AppAgentSetup.shared
        setup.chatViewModel = chatViewModel
        setup.coordinator = coordinator
        do {
            try setup.start()
        } catch {
            setup.startError = error.localizedDescription
            print("[NeoxApp] AppAgent MCP server failed to start: \(error)")
        }
        
        // On device: connect to bridge server for reverse MCP
        #if !targetEnvironment(simulator)
        setup.connectBridge(url: "ws://10.0.0.101:9224/ws")
        #endif
    }
}
