import SwiftUI

/// Neox — headless MCP server exposing the phone's photo library
/// to desktop agents. No chat, no channels: the status screen is the whole UI.
@main
struct NeoxApp: App {
    @StateObject private var bridge = BridgeServer.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StatusView()
                .environmentObject(bridge)
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
