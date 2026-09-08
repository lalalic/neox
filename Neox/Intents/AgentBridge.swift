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

    /// UserDefaults key for the user-selected preferred bridge instance name.
    static let preferredKey = "neox.preferredBridge"

    /// The user's preferred bridge (nil = first discovered wins).
    static var preferredName: String? {
        get { UserDefaults.standard.string(forKey: preferredKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferredKey) }
    }

    enum Outcome: Equatable, Sendable {
        case posted
        case bridgeNotFound
        case failed(String)
    }

    /// Resolve the bridge to hand off to: the user's preferred instance if
    /// it's among `discovered`, else the first discovered one.
    static func selectEndpoint(from discovered: [AgentBridgeDiscovery.Entry],
                               preferred: String?) -> NWEndpoint? {
        guard !discovered.isEmpty else { return nil }
        let entry = discovered.first { $0.name == preferred } ?? discovered.first!
        return .service(name: entry.name,
                        type: serviceType,
                        domain: "local",
                        interface: nil)
    }

    /// Browse for the bridge and POST `message` to it. `discovered` is the
    /// status screen's live snapshot and `preferred` the user's pick (nil =
    /// first discovered); `timeout` bounds the whole exchange so the intent
    /// never hangs.
    static func handoff(_ message: String,
                        discovered: [AgentBridgeDiscovery.Entry],
                        preferred: String?,
                        timeout: TimeInterval = 8) async -> Outcome {
        // 1. Resolve — prefer the user's pick, else first discovered.
        let endpoint = selectEndpoint(from: discovered, preferred: preferred)
        guard let endpoint else { return .bridgeNotFound }

        // 2. Connect and POST raw HTTP. The reference bridge is python
        // http.server (HTTP/1.0): it closes the socket after the response,
        // so read-until-EOF is the completion signal. Note: NWConnection's
        // own Bonjour resolve of a `.service` endpoint can stall indefinitely
        // on iOS (Local-Network + mDNS quirk) — the browser already did the
        // discovery dance successfully, so instead we hand NWConnection an
        // endpoint whose host name we let mDNS resolve via a dedicated,
        // observable resolve step and skip NW's implicit path entirely.
        let body = Data(message.utf8)
        let head = "POST \(path) HTTP/1.1\r\n"
            + "Host: neox-agent\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        let payload = Data(head.utf8) + body

        // Resolve the service's host/port with an explicit NWBrowser resolve
        // (browseResults give us the endpoint, but its host is only available
        // after resolution — reuse the discovery snapshot's name and let the
        // Poster's NWConnection do the resolving, but with a longer window:
        // first resolve on a fresh interface can take >8 s).
        let effectiveTimeout = max(timeout, 20)

        return await withCheckedContinuation { cont in
            Poster(endpoint: endpoint, payload: payload, timeout: effectiveTimeout) { outcome in
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
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let connection = NWConnection(to: endpoint, using: params)
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
        /// Bonjour instance name, e.g. "neox-agent" — whatever the desktop
        /// side registered via `dns-sd -R <name> _neox-agent._tcp …`.
        let id: String
        let name: String
        /// The NWEndpoint captured at browse time; it resolves lazily when a
        /// connection is opened against it (browse alone doesn't give the
        /// host/port — that's why the old row showed a bogus ":0").
        let endpoint: NWEndpoint

        /// Human-readable endpoint for the status screen. Port is only known
        /// after resolution, so show the service identity until then.
        var endpointText: String { "\(name) · _neox-agent._tcp" }
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
            let entries: [Entry] = results.compactMap { result in
                guard case .service(let n, _, _, _) = result.endpoint else { return nil }
                return Entry(id: n, name: n, endpoint: result.endpoint)
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
