import SwiftUI
import CopilotChat
import CopilotSDK

@main
struct NeoxApp: App {
    @StateObject private var coordinator = AgentCoordinator()
    
    init() {
        // Register BGTask handlers before app finishes launching
        PlanExecutor.shared.registerBGTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .task {
                    let vm = coordinator.createChatViewModel()
                    
                    // Configure PlanExecutor with relay settings and plan store
                    PlanExecutor.shared.configure(
                        planStore: vm.planStore,
                        relayHost: coordinator.relayHost,
                        relayPort: coordinator.relayPort
                    )
                    PlanExecutor.shared.scheduleNextCheck()
                    
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
        
        // On device: connect to bridge server for reverse MCP (when enabled in settings)
        #if !targetEnvironment(simulator)
        if coordinator.useDevServer {
            setup.connectBridge(url: "ws://10.0.0.101:\(coordinator.devServerPort)/ws")
        }
        #endif
    }
}
