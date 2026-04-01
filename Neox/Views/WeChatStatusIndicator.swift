import SwiftUI
import WebKitAgent

/// Small toolbar icon showing WeChat channel status.
///
/// - **Green**: Online and actively routing messages.
/// - **Yellow**: Online but routing paused or no contacts bound.
/// - **Gray**: Offline or service disabled.
///
/// Tap to toggle routing on/off. Long-press to open the contact selector.
struct WeChatStatusIndicator: View {
    @ObservedObject var weChatService: WeChatService
    let project: String?
    let onLongPress: () -> Void

    var body: some View {
        Button(action: {
            guard weChatService.config.enabled else { return }
            weChatService.toggleRouting(for: project)
        }) {
            Image(systemName: iconName)
                .font(.body)
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress() }
        )
        .accessibilityLabel("WeChat \(accessibilityStatus)")
    }

    private var iconName: String {
        guard weChatService.config.enabled else { return "ellipsis.bubble" }
        switch weChatService.channelState {
        case .ready:
            return weChatService.isRoutingActive(for: project)
                ? "ellipsis.bubble.fill"       // Online + routing
                : "ellipsis.bubble"             // Online + paused
        case .loading, .extractingQR, .qrReady, .loggingIn:
            return "ellipsis.bubble"            // Loading/QR states
        case .disconnected, .dead:
            return "ellipsis.bubble"            // Offline
        }
    }

    private var iconColor: Color {
        guard weChatService.config.enabled else { return .gray }
        switch weChatService.channelState {
        case .ready:
            return weChatService.isRoutingActive(for: project) ? .green : .yellow
        case .loading, .extractingQR, .qrReady, .loggingIn:
            return .orange
        case .disconnected, .dead:
            return .gray
        }
    }

    private var accessibilityStatus: String {
        guard weChatService.config.enabled else { return "disabled" }
        if weChatService.isOnline {
            return weChatService.isRoutingActive(for: project) ? "routing" : "paused"
        }
        return "offline"
    }
}
