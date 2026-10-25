import SwiftUI
@preconcurrency import RoyalVNCKit

/// Native RFB client. The socket endpoint is supplied by the remote transport;
/// production must route it through Neo's authenticated tunnel.
final class VNCViewerController: NSObject, ObservableObject, VNCConnectionDelegate, @unchecked Sendable {
    @Published var status = "Not connected"
    @Published var frame: CGImage?
    @Published var framebufferSize = CGSize.zero
    @Published var error: String?

    private var connection: VNCConnection?
    private let credentialLock = NSLock()
    private var credentials = (username: "", password: "")

    func connect(host: String, port: UInt16, username: String, password: String) {
        disconnect()
        credentialLock.withLock { credentials = (username, password) }
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: port,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: true,
            inputMode: .forwardKeyboardShortcutsEvenIfInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        let client = VNCConnection(settings: settings)
        connection = client
        client.delegate = self
        status = "Connecting…"
        client.connect()
    }

    func disconnect() {
        connection?.disconnect()
        connection?.delegate = nil
        connection = nil
        credentialLock.withLock { credentials.password = "" }
        status = "Not connected"
        frame = nil
    }

    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        guard let connection, framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        let x = UInt16(clamping: Int(relativeX * framebufferSize.width))
        let y = UInt16(clamping: Int(relativeY * framebufferSize.height))
        connection.mouseButtonDown(.left, x: x, y: y)
        connection.mouseButtonUp(.left, x: x, y: y)
    }

    func drag(relativeX: CGFloat, relativeY: CGFloat, starting: Bool, ending: Bool) {
        guard let connection, framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        let x = UInt16(clamping: Int(max(0, min(1, relativeX)) * framebufferSize.width))
        let y = UInt16(clamping: Int(max(0, min(1, relativeY)) * framebufferSize.height))
        if starting {
            connection.mouseButtonDown(.left, x: x, y: y)
        } else if ending {
            connection.mouseButtonUp(.left, x: x, y: y)
        } else {
            connection.mouseMove(x: x, y: y)
        }
    }

    func sendText(_ text: String) {
        guard let connection else { return }
        for key in VNCKeyCode.keyCodesFrom(characters: text) {
            connection.keyDown(key)
            connection.keyUp(key)
        }
    }

    func sendReturn() {
        connection?.keyDown(.return)
        connection?.keyUp(.return)
    }

    func connection(_ connection: VNCConnection, stateDidChange state: VNCConnection.ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            self?.status = String(describing: state.status)
            if let error = state.error { self?.error = error.localizedDescription }
        }
    }

    func connection(_ connection: VNCConnection, credentialFor type: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        let credential: VNCCredential?
        let saved = credentialLock.withLock { credentials }
        if type.requiresUsername {
            credential = VNCUsernamePasswordCredential(username: saved.username, password: saved.password)
        } else if type.requiresPassword {
            credential = VNCPasswordCredential(password: saved.password)
        } else {
            credential = nil
        }
        completion(credential)
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer buffer: VNCFramebuffer) {
        publish(buffer)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer buffer: VNCFramebuffer) {
        publish(buffer)
    }

    func connection(_ connection: VNCConnection, didUpdateFramebuffer buffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        publish(buffer)
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

    private func publish(_ buffer: VNCFramebuffer) {
        let image = buffer.cgImage
        DispatchQueue.main.async { [weak self] in
            self?.frame = image
            if let image { self?.framebufferSize = CGSize(width: image.width, height: image.height) }
        }
    }
}

struct VNCViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var remote: RemoteMCPClient
    @StateObject private var viewer = VNCViewerController()
    @State private var relay: VNCLoopbackRelay?
    @State private var username = ""
    @State private var password = ""
    @State private var input = ""
    @State private var dragging = false

    var body: some View {
        VStack(spacing: 10) {
            if viewer.frame == nil {
                Form {
                    Section("Your Mac screen") {
                        Text("See and control your Mac from your iPhone.").foregroundStyle(.secondary)
                        TextField("Mac account name", text: $username)
                            .textInputAutocapitalization(.never)
                        SecureField("Mac login password", text: $password)
                        Button("Connect") {
                            Task {
                                do {
                                    relay = try await remote.openVNCTunnel()
                                    guard let relay else { return }
                                    viewer.connect(host: "127.0.0.1", port: relay.port,
                                                   username: username, password: password)
                                    password = ""
                                } catch { viewer.error = error.localizedDescription }
                            }
                        }
                    }
                    Section {
                        Text(viewer.status)
                        if let error = viewer.error { Text(error).foregroundStyle(.red) }
                    }
                }
            } else if let image = viewer.frame {
                GeometryReader { geometry in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { point in
                            let imageRatio = CGFloat(image.width) / CGFloat(image.height)
                            let boundsRatio = geometry.size.width / max(geometry.size.height, 1)
                            let width = imageRatio > boundsRatio ? geometry.size.width : geometry.size.height * imageRatio
                            let height = imageRatio > boundsRatio ? geometry.size.width / imageRatio : geometry.size.height
                            let x = (point.x - (geometry.size.width - width) / 2) / width
                            let y = (point.y - (geometry.size.height - height) / 2) / height
                            guard (0...1).contains(x), (0...1).contains(y) else { return }
                            viewer.tap(relativeX: x, relativeY: y)
                        }
                        .simultaneousGesture(DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                let ratio = CGFloat(image.width) / CGFloat(image.height)
                                let bounds = geometry.size.width / max(geometry.size.height, 1)
                                let width = ratio > bounds ? geometry.size.width : geometry.size.height * ratio
                                let height = ratio > bounds ? geometry.size.width / ratio : geometry.size.height
                                let x = (value.location.x - (geometry.size.width - width) / 2) / width
                                let y = (value.location.y - (geometry.size.height - height) / 2) / height
                                viewer.drag(relativeX: x, relativeY: y, starting: !dragging, ending: false)
                                dragging = true
                            }
                            .onEnded { value in
                                guard dragging else { return }
                                let ratio = CGFloat(image.width) / CGFloat(image.height)
                                let bounds = geometry.size.width / max(geometry.size.height, 1)
                                let width = ratio > bounds ? geometry.size.width : geometry.size.height * ratio
                                let height = ratio > bounds ? geometry.size.width / ratio : geometry.size.height
                                viewer.drag(relativeX: (value.location.x - (geometry.size.width - width) / 2) / width,
                                            relativeY: (value.location.y - (geometry.size.height - height) / 2) / height,
                                            starting: false, ending: true)
                                dragging = false
                            })
                }
                HStack {
                    TextField("Type on your Mac", text: $input)
                    Button("Type") {
                        viewer.sendText(input)
                        input = ""
                    }
                    Button("Return") { viewer.sendReturn() }
                }.textFieldStyle(.roundedBorder)
            }
            Button("Finish", role: .destructive) {
                viewer.disconnect()
                relay?.close()
                relay = nil
            }
                .disabled(viewer.status == "Not connected")
        }
        .onDisappear { closeDesktop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { closeDesktop() }
        }
    }
    private func closeDesktop() {
        viewer.disconnect()
        relay?.close()
        relay = nil
        password = ""
    }

}
