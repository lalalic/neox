import CommonCrypto
import Foundation
import Network

/// An authenticated WebSocket to loopback-only RFB stream bridge.
/// Authorization is checked by MCPServer before accept is called.
final class VNCWebSocketProxy: @unchecked Sendable {
    static let shared = VNCWebSocketProxy()
    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private let limit = 2

    func isActive(_ browser: NWConnection) -> Bool {
        lock.withLock {
            sessions.values.contains { $0.browser === browser }
        }
    }

    func accept(_ browser: NWConnection, key: String) {
        guard let rawKey = Data(base64Encoded: key), rawKey.count == 16 else {
            reject(browser, status: 400)
            return
        }
        let id = UUID()
        let session = Session(id: id, browser: browser) { [weak self] id in
            self?.lock.withLock { self?.sessions.removeValue(forKey: id) }
        }
        let admitted = lock.withLock { () -> Bool in
            guard sessions.count < limit else { return false }
            sessions[id] = session
            return true
        }
        guard admitted else {
            reject(browser, status: 503)
            return
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let value = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        value.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(value.count), &digest)
        }
        let accept = Data(digest).base64EncodedString()
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: binary\r\n\r\n"
        browser.send(content: Data(response.utf8), completion: .contentProcessed { error in
            if error == nil { session.start() } else { session.close() }
        })
    }

    private func reject(_ connection: NWConnection, status: Int) {
        let reason = status == 503 ? "Service Unavailable" : "Bad Request"
        let data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private final class Session: @unchecked Sendable {
        let id: UUID
        let browser: NWConnection
        let remote = NWConnection(host: "127.0.0.1", port: 5900, using: .tcp)
        let onClose: (UUID) -> Void
        private let lock = NSLock()
        private var receiveBuffer = Data()
        private var closed = false

        init(id: UUID, browser: NWConnection, onClose: @escaping (UUID) -> Void) {
            self.id = id
            self.browser = browser
            self.onClose = onClose
        }

        func start() {
            remote.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.receiveTCP()
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            remote.start(queue: DispatchQueue(label: "neo.vnc.tcp.\(id)"))
            receiveWebSocket()
            DispatchQueue.global().asyncAfter(deadline: .now() + 8 * 60 * 60) { [weak self] in
                self?.close()
            }
        }

        func close() {
            let shouldClose = lock.withLock { () -> Bool in
                guard !closed else { return false }
                closed = true
                return true
            }
            guard shouldClose else { return }
            browser.cancel()
            remote.cancel()
            onClose(id)
        }

        private func receiveTCP() {
            remote.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.browser.send(content: Self.frame(opcode: 2, payload: data),
                                      completion: .contentProcessed { sendError in
                        if sendError != nil { self.close() }
                        else { self.receiveTCP() }
                    })
                } else if done || error != nil {
                    self.close()
                } else {
                    self.receiveTCP()
                }
            }
        }

        private func receiveWebSocket() {
            browser.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    let result = self.lock.withLock { () -> [Message]? in
                        self.receiveBuffer.append(data)
                        return self.parseFrames()
                    }
                    guard let frames = result else { self.close(); return }
                    for message in frames {
                        switch message.opcode {
                        case 0, 2:
                            self.remote.send(content: message.payload, completion: .contentProcessed { error in
                                if error != nil { self.close() }
                            })
                        case 8:
                            self.close()
                            return
                        case 9:
                            self.browser.send(content: Self.frame(opcode: 10, payload: message.payload),
                                              completion: .contentProcessed { _ in })
                        case 10:
                            break
                        default:
                            self.close()
                            return
                        }
                    }
                }
                if done || error != nil { self.close() }
                else { self.receiveWebSocket() }
            }
        }

        private struct Message {
            var opcode: UInt8
            var payload: Data
        }

        /// Parses masked RFC 6455 frames; incomplete data remains buffered.
        /// A malformed or oversized frame closes only its own session.
        private func parseFrames() -> [Message]? {
            var messages: [Message] = []
            while receiveBuffer.count >= 2 {
                let first = receiveBuffer[0]
                let second = receiveBuffer[1]
                guard first & 0x70 == 0, second & 0x80 != 0 else { return nil }
                let opcode = first & 0x0f
                guard [UInt8(0), 2, 8, 9, 10].contains(opcode) else { return nil }
                let isControl = opcode >= 8
                guard !isControl || (first & 0x80 != 0) else { return nil }
                var size = UInt64(second & 0x7f)
                var index = 2
                if size == 126 {
                    guard receiveBuffer.count >= index + 2 else { break }
                    size = UInt64(receiveBuffer[index]) << 8 | UInt64(receiveBuffer[index + 1])
                    index += 2
                } else if size == 127 {
                    guard receiveBuffer.count >= index + 8 else { break }
                    size = 0
                    for byte in receiveBuffer[index..<(index + 8)] { size = size << 8 | UInt64(byte) }
                    index += 8
                }
                guard size <= 1_048_576, !isControl || size <= 125 else { return nil }
                guard receiveBuffer.count >= index + 4 + Int(size) else { break }
                let mask = Array(receiveBuffer[index..<(index + 4)])
                index += 4
                let bytes = receiveBuffer[index..<(index + Int(size))]
                let payload = Data(bytes.enumerated().map { offset, byte in
                    byte ^ mask[offset % 4]
                })
                receiveBuffer.removeSubrange(0..<(index + Int(size)))
                messages.append(Message(opcode: opcode, payload: payload))
            }
            guard receiveBuffer.count <= 1_048_590 else { return nil }
            return messages
        }

        private static func frame(opcode: UInt8, payload: Data) -> Data {
            var bytes = Data([0x80 | opcode])
            if payload.count < 126 {
                bytes.append(UInt8(payload.count))
            } else if payload.count <= 65535 {
                bytes.append(126)
                bytes.append(UInt8((payload.count >> 8) & 0xff))
                bytes.append(UInt8(payload.count & 0xff))
            } else {
                bytes.append(127)
                let length = UInt64(payload.count)
                for shift in stride(from: 56, through: 0, by: -8) {
                    bytes.append(UInt8((length >> shift) & 0xff))
                }
            }
            bytes.append(payload)
            return bytes
        }
    }
}
