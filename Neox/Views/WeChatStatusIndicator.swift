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
                .foregroundStyle(weChatService.statusColor(for: project))
                .contentTransition(.symbolEffect(.replace))
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress() }
        )
        .accessibilityLabel("WeChat \(accessibilityStatus)")
    }

    private var iconName: String {
        guard weChatService.config.enabled else { return "message" }
        switch weChatService.channelState {
        case .ready:
            return weChatService.isRoutingActive(for: project)
                ? "message.fill"
                : "message.badge.clock.fill"
        case .loading, .extractingQR, .qrReady, .loggingIn:
            return "message.badge.circle.fill"
        case .disconnected, .dead:
            return "message"
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
