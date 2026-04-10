import SwiftUI
import WebKitAgent
import Photos

/// Full-screen sheet that auto-shows when WeChat QR code is ready for scanning.
/// Handles QR display, expiry refresh, and dismissal on login.
struct WeChatQRLoginView: View {
    @ObservedObject var weChatService: WeChatService
    @Environment(\.dismiss) private var dismiss
    @State private var savedToPhotos = false

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

                        // Save to Photos so user can scan from WeChat's album scanner
                        Button {
                            saveQRToPhotos(image)
                        } label: {
                            Label(savedToPhotos ? "Saved" : "Save to Photos",
                                  systemImage: savedToPhotos ? "checkmark.circle.fill" : "square.and.arrow.down")
                                .font(.subheadline)
                        }
                        .disabled(savedToPhotos)
                    }

                    Text("Open WeChat → Scan → Album to scan saved QR")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
        .onChange(of: weChatService.qrCodeURL) { _, _ in
            savedToPhotos = false
        }
        .presentationDetents([.medium, .large])
    }

    private func saveQRToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                if success {
                    Task { @MainActor in savedToPhotos = true }
                }
            }
        }
    }
}
