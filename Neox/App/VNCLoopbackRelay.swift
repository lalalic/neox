import Darwin
import Foundation

/// Local-only RFB bridge to the authenticated Neo WebSocket gateway.
/// The listening socket binds to 127.0.0.1 and is never exposed to the LAN.
final class VNCLoopbackRelay: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let url: URL
    private let token: String
    private let lock = NSLock()
    private var closed = false
    private var active: Session?

    private init(fd: Int32, port: UInt16, url: URL, token: String) {
        self.fd = fd
        self.port = port
        self.url = url
        self.token = token
    }

    static func start(url: URL, token: String) async throws -> VNCLoopbackRelay {
        guard url.scheme == "wss", url.host != nil, !token.isEmpty else {
            throw RelayError.invalidURL
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.socket(errno) }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { throw RelayError.socket(errno) }
            guard Darwin.listen(fd, 1) == 0 else { throw RelayError.socket(errno) }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &length)
                }
            }
            guard named == 0 else { throw RelayError.socket(errno) }
            let relay = VNCLoopbackRelay(fd: fd, port: UInt16(bigEndian: address.sin_port),
                                         url: url, token: token)
            relay.acceptInBackground()
            return relay
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func acceptInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            while !self.lock.withLock({ self.closed }) {
                let client = Darwin.accept(self.fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let admitted = self.lock.withLock { () -> Session? in
                    guard !self.closed, self.active == nil else { return nil }
                    let encoded = Data(self.token.utf8).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-")
                        .replacingOccurrences(of: "/", with: "_")
                        .replacingOccurrences(of: "=", with: "")
                    let ws = URLSession.shared.webSocketTask(
                        with: self.url, protocols: ["binary", "neo-auth." + encoded])
                    let session = Session(fd: client, websocket: ws) { [weak self] in
                        self?.lock.withLock { self?.active = nil }
                    }
                    self.active = session
                    return session
                }
                if let admitted { admitted.start() } else { Darwin.close(client) }
            }
        }
    }

    func close() {
        let session = lock.withLock { () -> Session? in
            guard !closed else { return nil }
            closed = true
            let current = active
            active = nil
            return current
        }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        session?.close()
    }

    private final class Session: @unchecked Sendable {
        private let fd: Int32
        private let websocket: URLSessionWebSocketTask
        private let onClose: () -> Void
        private let lock = NSLock()
        private let writeQueue = DispatchQueue(label: "neox.vnc.socket.write")
        private var closed = false

        init(fd: Int32, websocket: URLSessionWebSocketTask, onClose: @escaping () -> Void) {
            self.fd = fd
            self.websocket = websocket
            self.onClose = onClose
        }

        func start() {
            var suppress = Int32(1)
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
            websocket.resume()
            receiveWebSocket()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.readSocket()
            }
        }

        func close() {
            let shouldClose = lock.withLock { () -> Bool in
                guard !closed else { return false }
                closed = true
                return true
            }
            guard shouldClose else { return }
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            websocket.cancel(with: .normalClosure, reason: nil)
            onClose()
        }

        private func readSocket() {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !lock.withLock({ closed }) {
                let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                if count <= 0 { break }
                let gate = SendGate()
                websocket.send(.data(Data(buffer.prefix(count)))) { error in
                    gate.finish(error)
                }
                if !gate.waitForSuccess() { break }
            }
            close()
        }

        private func receiveWebSocket() {
            websocket.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(.data(let bytes)):
                    self.writeQueue.async {
                        if self.writeAll(bytes) {
                            self.receiveWebSocket()
                        } else {
                            self.close()
                        }
                    }
                case .success(.string), .failure:
                    self.close()
                @unknown default:
                    self.close()
                }
            }
        }

        private func writeAll(_ bytes: Data) -> Bool {
            bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return true }
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                    if count <= 0 { return false }
                    offset += count
                }
                return true
            }
        }
    }

    private final class SendGate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var failed = false

        func finish(_ error: Error?) {
            lock.withLock { failed = error != nil }
            semaphore.signal()
        }

        func waitForSuccess() -> Bool {
            guard semaphore.wait(timeout: .now() + 30) == .success else { return false }
            return lock.withLock { !failed }
        }
    }

    private enum RelayError: LocalizedError {
        case invalidURL
        case socket(Int32)
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Your Mac connection is not configured."
            case .socket(let code): "Could not start screen sharing (\(code))."
            }
        }
    }
}
