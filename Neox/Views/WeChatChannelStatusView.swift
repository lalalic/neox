import SwiftUI
import WebKitAgent

/// Displays the WeChat channel status within Settings.
///
/// Shows state label, QR code when needed for login, and logged-in user info.
struct WeChatChannelStatusView: View {
    @ObservedObject var weChatService: WeChatService

    var body: some View {
        // Status row
        HStack {
            Text("Status")
            Spacer()
            Text(statusLabel)
                .foregroundStyle(statusLabelColor)
                .font(.footnote.weight(.semibold))
        }

        // QR code for login
        if let qrURL = weChatService.qrCodeURL,
           weChatService.channelState == .qrReady || weChatService.channelState == .extractingQR {
            VStack(spacing: 8) {
                Text("Scan with WeChat to log in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let image = WeChatChannel.generateQRCode(from: qrURL, size: 200) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(8)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }

        // Logging in state
        if weChatService.channelState == .loggingIn {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Confirming on phone…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // Logged-in user
        if let user = weChatService.loggedInUser {
            HStack {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.green)
                Text(user.name)
                    .font(.footnote)
                Spacer()
                Text("\(weChatService.contacts.count) contacts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // Dead / retry
        if weChatService.channelState == .dead {
            Button("Restart Channel") {
                weChatService.channel?.restart()
            }
            .font(.footnote)
        }
    }

    private var statusLabel: String {
        switch weChatService.channelState {
        case .disconnected: return "Disconnected"
        case .loading: return "Loading…"
        case .extractingQR: return "Extracting QR…"
        case .qrReady: return "Scan QR Code"
        case .loggingIn: return "Logging In…"
        case .ready: return "Online"
        case .dead: return "Session Expired"
        }
    }

    private var statusLabelColor: Color {
        switch weChatService.channelState {
        case .ready: return .green
        case .dead: return .red
        case .loading, .extractingQR, .qrReady, .loggingIn: return .orange
        case .disconnected: return .secondary
        }
    }
}
