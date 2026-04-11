import SwiftUI
import WebKitAgent

/// Full-screen sheet that auto-shows when WeChat QR code is ready for scanning.
struct WeChatQRLoginView: View {
    @ObservedObject var weChatService: WeChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
            
                if let qrURL = weChatService.qrCodeURL {
                    Text("WeChat Login")
                        .font(.title2.weight(.semibold))

                    if let image = WeChatBridge.generateQRCode(from: qrURL, size: 240) {
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
                } else {
                    ProgressView()
                        .controlSize(.large)
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
