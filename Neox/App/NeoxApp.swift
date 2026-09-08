import SwiftUI

/// Neox — headless MCP server exposing the phone's photo library
/// to desktop agents. No chat, no channels: the status screen is the whole UI.
@main
struct NeoxApp: App {
    @StateObject private var bridge = ServerController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environmentObject(bridge)
                // Inject directly on the overlay: environmentObject on the
                // parent doesn't reach .overlay content on all iOS versions
                // and crashes DemoOverlayView's @EnvironmentObject lookup.
                .overlay { DemoOverlayView().environmentObject(bridge.agentKit.demoRuntime) }
                .onChange(of: scenePhase) { phase in
                    // iOS may tear the listener down while backgrounded —
                    // restart on every foreground activation.
                    if phase == .active {
                        bridge.ensureRunning()
                    }
                }
        }
    }
}
