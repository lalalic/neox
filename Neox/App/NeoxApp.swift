import SwiftUI

/// Neox — headless MCP server exposing the phone's photo library
/// to desktop agents. No chat, no channels: the status screen is the whole UI.
@main
struct NeoxApp: App {
    @StateObject private var bridge = ServerController.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var enteredBackground = false

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environmentObject(bridge)
                // Inject directly on the overlay: environmentObject on the
                // parent doesn't reach .overlay content on all iOS versions
                // and crashes DemoOverlayView's @EnvironmentObject lookup.
                .overlay { DemoOverlayView().environmentObject(bridge.agentKit.demoRuntime) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .background:
                        enteredBackground = true
                    case .active:
                        bridge.ensureRunning()
                        if enteredBackground {
                            enteredBackground = false
                            Task { await bridge.recoverAfterBackgroundIfNeeded() }
                        }
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
