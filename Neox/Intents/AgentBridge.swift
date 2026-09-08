import Foundation
import Network

/// Phone-side half of the agent-bridge contract.
///
/// The desktop bridge advertises `_neox-agent._tcp` (TXT `path=/agent`) — the
/// mirror of this app's `neox._mcp._tcp`. Discovery means the phone never
/// holds a bridge address: browse → connect to the resolved endpoint → speak
/// minimal HTTP/1.1 by hand (raw `NWConnection`, no URLSession, no
/// host-name resolution needed) → POST the handoff.
enum AgentBridge {

    /// Bonjour service type the desktop bridge advertises.
    static let serviceType = "_neox-agent._tcp"
    /// Fixed POST path of the bridge contract (also advertised in TXT).
    static let path = "/agent"

    enum Outcome: Equatable {
        case posted
        case bridgeNotFound
        case failed(String)
    }

    /// Browse for the bridge and POST `message` to it. `timeout` bounds the
    /// whole browse+exchange; background automations keep this short so the
    /// intent never hangs.
    static func handoff(_ message: String, timeout: TimeInterval = 8) async -> Outcome {
        // 1. Browse — first advertised instance wins.
        let endpoint: NWEndpoint? = await withCheckedContinuation { cont in
            let gate = Gate()
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            let queue = DispatchQueue(label: "neox.bridge.browse")
            gate.onTimeout(queue: queue, after: timeout) { cont.resume(returning: nil) }
            browser.browseResultsChangedHandler = { results, _ in
                let resolved = results.first?.endpoint
                browser.cancel()
                gate.runOnce { cont.resume(returning: resolved) }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("neox bridge browse failed: \(error)")
                    gate.runOnce { cont.resume(returning: nil) }
                }
            }
            browser.start(queue: queue)
        }
        guard let endpoint else { return .bridgeNotFound }

        // 2. Connect and POST raw HTTP. The reference bridge is python
        // http.server (HTTP/1.0): it closes the socket after the response,
        // so read-until-EOF is the completion signal.
        let body = Data(message.utf8)
        let head = "POST \(path) HTTP/1.1\r\n"
            + "Host: neox-agent\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        let payload = Data(head.utf8) + body

        return await withCheckedContinuation { cont in
            Poster(endpoint: endpoint, payload: payload, timeout: timeout) { outcome in
                cont.resume(returning: outcome)
            }.start()
        }
    }

    /// One POST exchange over a single NWConnection. `@unchecked Sendable`:
    /// all mutable state (buffer, gate) is confined to the connection's
    /// serial queue + the NSLock inside `Gate`.
    private final class Poster: @unchecked Sendable {
        private let connection: NWConnection
        private let payload: Data
        private let gate = Gate()
        private var buffer = Data()
        private let onDone: @Sendable (Outcome) -> Void

        init(endpoint: NWEndpoint, payload: Data, timeout: TimeInterval,
             onDone: @escaping @Sendable (Outcome) -> Void) {
            let connection = NWConnection(to: endpoint, using: .tcp)
            self.connection = connection
            self.payload = payload
            self.onDone = onDone
            gate.onTimeout(queue: DispatchQueue(label: "neox.bridge.post.timer"), after: timeout) {
                connection.cancel()
                onDone(.failed("timeout waiting for bridge"))
            }
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.send()
                    self?.readLoop()
                case .failed(let error):
                    self?.complete(.failed("connect: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "neox.bridge.post"))
        }

        private func send() {
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.complete(.failed("send: \(error.localizedDescription)"))
                    self?.connection.cancel()
                }
            })
        }

        /// Read-until-EOF: the reference bridge (python http.server, HTTP/1.0)
        /// closes the socket after the response, so EOF is the completion.
        private func readLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                guard !isComplete && error == nil else {
                    let status = String(decoding: buffer.prefix(64), as: UTF8.self)
                    let firstLine = status.split(separator: "\r").first.map(String.init) ?? "no reply"
                    connection.cancel()
                    complete(status.contains(" 200") ? .posted : .failed("bridge said: \(firstLine)"))
                    return
                }
                readLoop()
            }
        }

        private func complete(_ outcome: Outcome) {
            gate.runOnce { onDone(outcome) }
        }
    }

    /// One-shot latch: exactly one `runOnce` body (or the timeout body) ever
    /// executes, no matter how many Network callbacks race. `@unchecked
    /// Sendable` because all state sits behind an NSLock — the same pattern
    /// as the repo's OnceContinuation.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true

        /// Runs `body` if this is the first finish; returns whether it ran.
        @discardableResult
        func runOnce(_ body: () -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if open { open = false; body(); return true }
            return false
        }

        /// Safety net: run `body` if the exchange hasn't completed in time.
        func onTimeout(queue: DispatchQueue, after seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) {
            queue.asyncAfter(deadline: .now() + seconds) { [self] in
                runOnce(body)
            }
        }
    }
}

/// Continuous Bonjour browse for agent bridges, feeding the status screen.
/// `entries()` is an AsyncSequence of the current snapshot, re-emitted on
/// every change — the caller stores it into a `@Published` property.
@MainActor
final class AgentBridgeDiscovery: ObservableObject {

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let host: String
        let port: UInt16

        /// Human-readable endpoint for the status screen.
        var description: String { "\(host):\(port)\(AgentBridge.path)" }
    }

    private let emitter = Emitter()
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "neox.bridge.discover")

    nonisolated func entries() -> AsyncStream<[Entry]> {
        emitter.stream
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: AgentBridge.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries: [Entry] = results.map { result in
                // Service endpoints at browse time carry (name, type, domain,
                // interface) — no port and no resolved host yet. Show the
                // instance name; the actual host:port resolves when the
                // handoff connects.
                var name = "?"
                if case .service(let n, _, _, _) = result.endpoint {
                    name = n
                }
                return Entry(id: name, name: name, host: name, port: 0)
            }
            Task { @MainActor [weak self] in
                self?.emitter.emit(entries)
            }
        }
        browser.stateUpdateHandler = { _ in }
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Fan-out of the latest snapshot to however many streams exist.
    private final class Emitter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [UUID: AsyncStream<[Entry]>.Continuation] = [:]

        var stream: AsyncStream<[Entry]> {
            AsyncStream { continuation in
                let id = UUID()
                lock.lock()
                continuations[id] = continuation
                lock.unlock()
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    self.continuations[id] = nil
                    self.lock.unlock()
                }
            }
        }

        func emit(_ entries: [Entry]) {
            lock.lock()
            let all = Array(continuations.values)
            lock.unlock()
            for c in all { c.yield(entries) }
        }
    }
}
