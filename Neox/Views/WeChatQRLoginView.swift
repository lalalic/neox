import SwiftUI
import WebKitAgent

/// Full-screen sheet that auto-shows when WeChat QR code is ready for scanning.
/// Handles QR display, expiry refresh, and dismissal on login.
struct WeChatQRLoginView: View {
    @ObservedObject var weChatService: WeChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "ellipsis.bubble.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("WeChat Login")
                    .font(.title2.weight(.semibold))

                if let qrURL = weChatService.qrCodeURL {
                    if let image = WeChatChannel.generateQRCode(from: qrURL, size: 240) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(12)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: .black.opacity(0.1), radius: 8)
                    }

                    Text("Scan with WeChat to log in")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading QR code…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if weChatService.channelState == .loggingIn {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Confirming on phone…")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: weChatService.channelState) { _, newState in
            if newState == .ready {
                dismiss()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
