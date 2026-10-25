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
    private var connectStartedAt: Date?
    private var firstFrameReported = false

    func connect(host: String, port: UInt16, username: String, password: String) {
        disconnect()
        connectStartedAt = Date()
        firstFrameReported = false
        error = nil
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
            colorDepth: .depth16Bit,
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
        framebufferSize = .zero
    }

    func tap(relativeX: CGFloat, relativeY: CGFloat) {
        guard let connection, framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        let x = UInt16(clamping: Int(relativeX * framebufferSize.width))
        let y = UInt16(clamping: Int(relativeY * framebufferSize.height))
        connection.mouseButtonDown(.left, x: x, y: y)
        connection.mouseButtonUp(.left, x: x, y: y)
    }

    func rightClick(relativeX: CGFloat, relativeY: CGFloat) {
        guard let connection, framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        let x = UInt16(clamping: Int(relativeX * framebufferSize.width))
        let y = UInt16(clamping: Int(relativeY * framebufferSize.height))
        connection.mouseButtonDown(.right, x: x, y: y)
        connection.mouseButtonUp(.right, x: x, y: y)
    }

    func scroll(relativeX: CGFloat, relativeY: CGFloat, horizontal: Int, vertical: Int) {
        guard let connection, framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        let x = UInt16(clamping: Int(relativeX * framebufferSize.width))
        let y = UInt16(clamping: Int(relativeY * framebufferSize.height))
        if vertical != 0 {
            connection.mouseWheel(vertical > 0 ? .down : .up, x: x, y: y,
                                  steps: UInt32(min(30, abs(vertical))))
        }
        if horizontal != 0 {
            connection.mouseWheel(horizontal > 0 ? .left : .right, x: x, y: y,
                                  steps: UInt32(min(30, abs(horizontal))))
        }
    }

    func backspace() {
        connection?.keyDown(.delete)
        connection?.keyUp(.delete)
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
            guard let self, self.connection === connection else { return }
            switch state.status {
            case .disconnected: self.status = "Not connected"
            case .connecting: self.status = "Connecting…"
            case .connected: self.status = "Connected"
            case .disconnecting: self.status = "Closing…"
            }
            if let error = state.error { self.error = error.localizedDescription }
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
        publish(buffer, from: connection)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer buffer: VNCFramebuffer) {
        publish(buffer, from: connection)
    }

    func connection(_ connection: VNCConnection, didUpdateFramebuffer buffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        publish(buffer, from: connection)
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}

    private func publish(_ buffer: VNCFramebuffer, from connection: VNCConnection) {
        let image = buffer.cgImage
        if image != nil && !firstFrameReported {
            firstFrameReported = true
            if let start = connectStartedAt {
                NSLog("Neo Desktop: VNC first frame after %.2f s", Date().timeIntervalSince(start))
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connection === connection else { return }
            self.frame = image
            if let image { self.framebufferSize = CGSize(width: image.width, height: image.height) }
        }
    }
}

@MainActor
final class RemoteDesktopResources: ObservableObject {
    var relay: VNCLoopbackRelay?

    func close() {
        relay?.close()
        relay = nil
    }
}

struct VNCViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var remote: RemoteMCPClient
    @ObservedObject var viewer: VNCViewerController
    @ObservedObject var resources: RemoteDesktopResources
    @State private var username = ""
    @State private var password = ""
    @State private var input = ""
    @State private var passwordInInput = false
    @FocusState private var keyboardActive: Bool
    @State private var connectionGeneration = 0
    @State private var automaticRetries = 0

    var body: some View {
        VStack(spacing: 10) {
            if viewer.frame == nil {
                VStack(spacing: 14) {
                    if viewer.error == nil {
                        ProgressView("Loading your desktop…")
                    } else {
                        Text("Could not show your desktop.")
                        Text(viewer.error ?? "").font(.caption).foregroundStyle(.secondary)
                        Button("Try again") { connectDesktop() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = viewer.frame {
                RemoteDesktopCanvas(image: image,
                                    onClick: { viewer.tap(relativeX: $0, relativeY: $1) },
                                    onRightClick: { viewer.rightClick(relativeX: $0, relativeY: $1) },
                                    onDrag: { viewer.drag(relativeX: $0, relativeY: $1,
                                                          starting: $2, ending: $3) },
                                    onScroll: { viewer.scroll(relativeX: $0, relativeY: $1,
                                                              horizontal: $2, vertical: $3) })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Mac desktop")
                    .accessibilityIdentifier("remoteDesktopCanvas")
                Text("Tap to click · Double-tap to zoom · Pinch to resize · Two fingers to move or scroll · Hold for right-click")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                HStack(spacing: 12) {
                    Button { keyboardActive = true } label: {
                        Image(systemName: "keyboard")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Open keyboard")
                    Button {
                        if let saved = MacScreenCredentials.load(for: remote.endpoint) {
                            input = saved.password
                            passwordInInput = true
                        }
                    } label: {
                        Image(systemName: "key.fill")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Type saved password")
                    .disabled(MacScreenCredentials.load(for: remote.endpoint) == nil)
                    Spacer()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                HStack(spacing: 12) {
                    Group {
                        if passwordInInput {
                            SecureField("Password ready", text: $input)
                                .onSubmit(sendInputAndReturn)
                        } else {
                            TextField("Type on your Mac", text: $input)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit(sendInputAndReturn)
                        }
                    }
                    .focused($keyboardActive)
                    Button { sendInputAndReturn() } label: {
                        Image(systemName: "return")
                    }
                    .accessibilityLabel("Return")
                }
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .onAppear {
            if resources.relay == nil && viewer.status == "Not connected",
               let saved = MacScreenCredentials.load(for: remote.endpoint) {
                username = saved.username
                password = saved.password
                connectDesktop()
            }
        }
        .onChange(of: viewer.error) { _, message in
            guard let message, message.contains("Receive Server Init"),
                  automaticRetries < 1 else { return }
            automaticRetries += 1
            let generation = connectionGeneration
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                guard generation == connectionGeneration else { return }
                connectDesktop(retrying: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // A brief inactive transition is not a request to disconnect.
            // iOS may suspend the socket in the background; reconnect only if it died.
            if phase == .active && viewer.status == "Not connected" { connectDesktop() }
        }
    }
    private func connectDesktop(retrying: Bool = false) {
        if !retrying { automaticRetries = 0 }
        let saved = MacScreenCredentials.load(for: remote.endpoint)
        let name = username.isEmpty ? (saved?.username ?? "") : username
        let secret = password.isEmpty ? (saved?.password ?? "") : password
        guard !name.isEmpty, !secret.isEmpty else {
            viewer.error = "Enter your Mac account and password."
            return
        }
        do {
            try MacScreenCredentials.save(username: name, password: secret, for: remote.endpoint)
        } catch {
            viewer.error = error.localizedDescription
            return
        }
        closeDesktop()
        let generation = connectionGeneration
        Task {
            do {
                let tunnelStartedAt = Date()
                let created = try await remote.openVNCTunnel()
                NSLog("Neo Desktop: tunnel ready after %.2f s", Date().timeIntervalSince(tunnelStartedAt))
                guard generation == connectionGeneration else {
                    created.close()
                    return
                }
                resources.relay = created
                viewer.connect(host: "127.0.0.1", port: created.port,
                               username: name, password: secret)
                password = ""
            } catch {
                if generation == connectionGeneration { viewer.error = error.localizedDescription }
            }
        }
    }

    private func closeDesktop() {
        connectionGeneration += 1
        viewer.disconnect()
        keyboardActive = false
        input = ""
        passwordInInput = false
        resources.close()
        password = ""
    }

    private func sendInputAndReturn() {
        if !input.isEmpty {
            viewer.sendText(input)
        }
        viewer.sendReturn()
        input = ""
        passwordInInput = false
    }

}
