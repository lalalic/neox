import SwiftUI
import CopilotChat

@main
struct NeoxApp: App {
    @StateObject private var coordinator = AgentCoordinator()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .task {
                    let _ = coordinator.createChatViewModel()
                    startAppAgent(coordinator: coordinator)
                }
        }
    }
    
    private func startAppAgent(coordinator: AgentCoordinator) {
        let setup = AppAgentSetup.shared
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
