import SwiftUI
import WebKitAgent

/// Small toolbar icon showing WeChat channel status.
///
/// - **Green**: Online (filled = routing active).
/// - **Green + slash**: Online but routing off.
/// - **Orange**: Kicked off / session expired (tap to re-login).
/// - **Gray**: Offline, loading, or service disabled.
///
/// Tap: toggle routing (when online), or re-login (when kicked off).
/// Long-press: open the contact selector.
struct WeChatStatusIndicator: View {
    @ObservedObject var weChatService: WeChatService
    let project: String?
    let onLongPress: () -> Void

    var body: some View {
        Button(action: {
            guard weChatService.config.enabled else { return }
            switch weChatService.channelState {
            case .dead, .disconnected:
                weChatService.restart()
            case .ready:
                weChatService.toggleRouting(for: project)
            default:
                break  // loading / extracting / qrReady / loggingIn — do nothing
            }
        }) {
            ZStack {
                Image(systemName: iconName)
                    .font(.body)
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace))

                // Slash overlay when online but routing off
                if showSlash {
                    Image(systemName: "line.diagonal")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                        .rotationEffect(.degrees(45))
                }
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in onLongPress() }
        )
        .accessibilityLabel("WeChat \(accessibilityStatus)")
    }

    private var iconName: String {
        "ellipsis.bubble.fill"
    }

    private var iconColor: Color {
        guard weChatService.config.enabled else { return .gray }
        switch weChatService.channelState {
        case .ready:
            return .green
        case .loading, .extractingQR, .qrReady, .loggingIn:
            return .gray  // still loading
        case .dead:
            return .orange  // kicked off — tap to re-login
        case .disconnected:
            return .gray
        }
    }

    private var showSlash: Bool {
        weChatService.config.enabled
            && weChatService.channelState == .ready
            && !weChatService.isRoutingActive(for: project)
    }

    private var accessibilityStatus: String {
        guard weChatService.config.enabled else { return "disabled" }
        if weChatService.isOnline {
            return weChatService.isRoutingActive(for: project) ? "routing" : "paused"
        }
        if weChatService.channelState == .dead { return "kicked off, tap to re-login" }
        return "offline"
    }
}
