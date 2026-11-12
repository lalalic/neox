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
            VStack(spacing: 0) {
                topNavigation
                TabView(selection: $selectedTab) {
                ChatGatewayView(master: savedMaster, isActive: selectedTab == .chat)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(MobileTab.chat)
                    .toolbar(.hidden, for: .tabBar)
                RelayJobsView(master: savedMaster)
                    .tabItem { Label("Jobs", systemImage: "list.bullet.rectangle") }
                    .tag(MobileTab.jobs)
                    .toolbar(.hidden, for: .tabBar)
                MarkcutReviewInboxView(
                    requestedPreviewID: reviewPush.tappedRequestID, asTab: true,
                    isPilotActive: selectedTab == .reviews
                )
                    .tabItem { Label("Review Inbox", systemImage: "checkmark.rectangle.stack") }
                    .tag(MobileTab.reviews)
                    .toolbar(.hidden, for: .tabBar)
                StatusView()
                    .tabItem { Label("Connector", systemImage: "cable.connector") }
                    .tag(MobileTab.connector)
                    .toolbar(.hidden, for: .tabBar)
                }
                .toolbar(.hidden, for: .tabBar)
            }
                .environmentObject(savedMaster)
                .environmentObject(bridge)
                // Inject directly on the overlay: environmentObject on the
                // parent doesn't reach .overlay content on all iOS versions
                // and crashes DemoOverlayView's @EnvironmentObject lookup.
                .overlay { DemoOverlayView().environmentObject(bridge.agentKit.demoRuntime) }
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

    private var topNavigation: some View {
        HStack(spacing: 4) {
            topButton(.chat, "Chat", "bubble.left.and.bubble.right", "chat")
            topButton(.jobs, "Jobs", "list.bullet.rectangle", "jobs")
            topButton(.reviews, "Review", "checkmark.rectangle.stack", "reviews")
            topButton(.connector, "Connector", "cable.connector", "connector")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func topButton(_ destination: MobileTab, _ title: String,
                           _ symbol: String, _ key: String) -> some View {
        let selected = selectedTab == destination
        let color = destination == .connector ? connectorStatusColor :
            (selected ? Color.accentColor : Color.secondary)
        return Button { selectedTab = destination } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .frame(height: 43)
            .background(selected ? color.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(destination == .connector ? connectorStatusLabel : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("neoTopTab" + key.capitalized)
        .appCopilotAction(id: "neox.tab." + key, label: title,
                          isVisible: true) { selectedTab = destination }
    }
    private var connectorStatusColor: Color {
        switch bridge.state {
        case .running: .green
        case .failed: .red
        case .starting, .idle: .orange
        }
    }

    private var connectorStatusLabel: String {
        switch bridge.state {
        case .running: "iPhone connector ready"
        case .failed: "iPhone connector failed"
        case .starting: "iPhone connector starting"
        case .idle: "iPhone connector idle"
        }
    }

}
