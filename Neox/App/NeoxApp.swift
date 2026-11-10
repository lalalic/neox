import AppCopilotKit
import SwiftUI

/// Neo Mobile: Chat, Relay Jobs, Markcut Review Inbox and phone Connector.
@main
struct NeoxApp: App {
    @UIApplicationDelegateAdaptor(MarkcutReviewNotificationDelegate.self) private var reviewNotifications
    @StateObject private var bridge = ServerController.shared
    @StateObject private var savedMaster = RemoteMCPClient()
    @StateObject private var reviewPush = ReviewPushCoordinator.shared
    @State private var selectedTab: MobileTab = .chat

    private enum MobileTab: Hashable {
        case chat, jobs, reviews, connector
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var enteredBackground = false

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ChatGatewayView(master: savedMaster, isActive: selectedTab == .chat)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(MobileTab.chat)
                RelayJobsView(master: savedMaster)
                    .tabItem { Label("Jobs", systemImage: "list.bullet.rectangle") }
                    .tag(MobileTab.jobs)
                MarkcutReviewInboxView(
                    requestedPreviewID: reviewPush.tappedRequestID, asTab: true,
                    isPilotActive: selectedTab == .reviews
                )
                    .tabItem { Label("Review Inbox", systemImage: "checkmark.rectangle.stack") }
                    .tag(MobileTab.reviews)
                StatusView()
                    .tabItem { Label("Connector", systemImage: "cable.connector") }
                    .tag(MobileTab.connector)
            }
                .environmentObject(savedMaster)
                .environmentObject(bridge)
                // Inject directly on the overlay: environmentObject on the
                // parent doesn't reach .overlay content on all iOS versions
                // and crashes DemoOverlayView's @EnvironmentObject lookup.
                .overlay { DemoOverlayView().environmentObject(bridge.agentKit.demoRuntime) }
                .onAppear { registerPilotTabs() }
                .onDisappear { unregisterPilotTabs() }
                .onReceive(NotificationCenter.default.publisher(for: .markcutReviewNotificationTapped)) { _ in
                    selectedTab = .reviews
                }
                .onChange(of: reviewPush.tappedRequestID, initial: true) { _, id in
                    if id != nil { selectedTab = .reviews }
                }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-markcut-notification-route-fixture") {
                        reviewPush.notificationTapped("fixture-standalone-preview")
                    }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .background:
                        enteredBackground = true
                    case .active:
                        bridge.ensureRunning()
                        Task {
                            await ReviewPushCoordinator.shared.retryRegistration()
                            await ReviewPushCoordinator.shared.recoverDeliveredNotifications()
                            await ReviewPushCoordinator.shared.syncPending()
                        }
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

    /// Explicit app-owned SwiftUI state changes: no private touch synthesis.
    /// The public package resolves UITabBar item frames at invocation time.
    private func registerPilotTabs() {
        let actions: [(String, String, MobileTab)] = [
            ("chat", "Chat", .chat),
            ("jobs", "Jobs", .jobs),
            ("reviews", "Review Inbox", .reviews),
            ("connector", "Connector", .connector)
        ]
        for (index, item) in actions.enumerated() {
            AppCopilotActionRegistry.shared.registerTab(
                id: "neox.tab.\(item.0)", label: item.1, index: index
            ) { selectedTab = item.2 }
        }
    }

    private func unregisterPilotTabs() {
        for id in ["chat", "jobs", "reviews", "connector"] {
            AppCopilotActionRegistry.shared.unregister(id: "neox.tab.\(id)")
        }
    }
}
