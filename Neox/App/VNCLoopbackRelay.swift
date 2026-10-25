import Foundation
import Network

/// A single-session local TCP facade for RoyalVNC. Raw RFB bytes travel only
/// over the authenticated Neo WSS endpoint; no public VNC port is opened.
final class VNCLoopbackRelay: @unchecked Sendable {
    let port: UInt16
    private let listener: NWListener
    private let url: URL
    private let token: String
    private let queue = DispatchQueue(label: "neox.vnc.relay")
    private let sessionLock = NSLock()
    private var active: Session?

    private init(listener: NWListener, port: UInt16, url: URL, token: String) {
        self.listener = listener
        self.port = port
        self.url = url
        self.token = token
    }

    static func start(url: URL, token: String) async throws -> VNCLoopbackRelay {
        guard url.scheme == "wss", url.host != nil, !token.isEmpty else {
            throw RelayError.invalidURL
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params, on: .any)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let boundPort = listener.port?.rawValue else {
                        if gate.claim() { continuation.resume(throwing: RelayError.noPort) }
                        return
                    }
                    let relay = VNCLoopbackRelay(listener: listener, port: boundPort, url: url, token: token)
                    listener.newConnectionHandler = { [weak relay] tcp in relay?.accept(tcp) }
                    if gate.claim() { continuation.resume(returning: relay) }
                case .failed(let error):
                    if gate.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if gate.claim() { continuation.resume(throwing: RelayError.cancelled) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "neox.vnc.listener"))
        }
    }

    private func accept(_ tcp: NWConnection) {
        guard sessionLock.withLock({ active == nil }) else { tcp.cancel(); return }
        let encoded = Data(token.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let websocket = URLSession.shared.webSocketTask(with: url, protocols: ["binary", "neo-auth." + encoded])
        let session = Session(tcp: tcp, websocket: websocket) { [weak self] in
            self?.sessionLock.withLock {
                if self?.active?.tcp === tcp { self?.active = nil }
            }
        }
        sessionLock.withLock { active = session }
        session.start(queue: queue)
    }

    func close() {
        listener.cancel()
        let current = sessionLock.withLock { () -> Session? in
            let value = active
            active = nil
            return value
        }
        current?.close()
    }

    private final class Session: @unchecked Sendable {
        let tcp: NWConnection
        let websocket: URLSessionWebSocketTask
        let onClose: () -> Void
        private let lock = NSLock()
        private var closed = false

        init(tcp: NWConnection, websocket: URLSessionWebSocketTask, onClose: @escaping () -> Void) {
            self.tcp = tcp
            self.websocket = websocket
            self.onClose = onClose
        }

        func start(queue: DispatchQueue) {
            tcp.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.readTCP()
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            tcp.start(queue: queue)
            websocket.resume()
            readWebSocket()
        }

        func close() {
            let shouldClose = lock.withLock { () -> Bool in
                guard !closed else { return false }
                closed = true
                return true
            }
            guard shouldClose else { return }
            tcp.cancel()
            websocket.cancel(with: .normalClosure, reason: nil)
            onClose()
        }

        private func readTCP() {
            tcp.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.websocket.send(.data(data)) { sendError in
                        if sendError != nil { self.close() } else { self.readTCP() }
                    }
                } else if done || error != nil {
                    self.close()
                } else {
                    self.readTCP()
                }
            }
        }

        private func readWebSocket() {
            websocket.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(.data(let data)):
                    self.tcp.send(content: data, completion: .contentProcessed { error in
                        if error != nil { self.close() } else { self.readWebSocket() }
                    })
                case .success(.string):
                    self.close()
                case .failure:
                    self.close()
                @unknown default:
                    self.close()
                }
            }
        }
    }

    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.withLock {
                guard !used else { return false }
                used = true
                return true
            }
        }
    }

    private enum RelayError: LocalizedError {
        case invalidURL, noPort, cancelled
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Neo VNC needs an authenticated WSS endpoint."
            case .noPort: "Could not bind the local VNC session."
            case .cancelled: "VNC session was cancelled."
            }
        }
    }
}
