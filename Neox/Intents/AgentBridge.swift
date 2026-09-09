import Foundation
import Network

/// Phone-side half of the agent-bridge contract.
///
/// The desktop bridge ("Neoy") advertises `_neoy._tcp` with TXT records
/// carrying the machine name (`host=`), port (`port=`), and LAN IP (`ip=`).
/// Discovery means the phone never hardcodes a bridge address: browse →
/// read TXT metadata → POST via URLSession to the IP directly (bypassing
/// iOS's Local Network gate that silently blocks raw NWConnection).
enum AgentBridge {

    /// Bonjour service type the desktop bridge advertises.
    static let serviceType = "_neoy._tcp"
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

    /// Browse for the bridge and POST `message` to it. `discovered` is the
    /// status screen's live snapshot and `preferred` the user's pick (nil =
    /// first discovered); `timeout` bounds the whole exchange so the intent
    /// never hangs.
    ///
    /// Uses URLSession (not raw NWConnection) — iOS's Local Network privacy
    /// gate silently blocks NWConnection to raw IPs and .local hostnames,
    /// but URLSession triggers the permission prompt and honors the grant.
    static func handoff(_ message: String,
                        discovered: [AgentBridgeDiscovery.Entry],
                        preferred: String?,
                        timeout: TimeInterval = 8) async -> Outcome {
        guard !discovered.isEmpty else { return .bridgeNotFound }
        let entry = discovered.first { $0.name == preferred } ?? discovered.first!

        // Build the URL from TXT metadata. IP is preferred (no DNS lookup).
        let hostPart: String
        if let ip = entry.ip {
            hostPart = ip
        } else if let host = entry.host {
            hostPart = host.hasSuffix(".local") ? host : "\(host).local"
        } else {
            return .failed("bridge has no host/ip in TXT")
        }
        guard let port = entry.port else { return .failed("bridge has no port in TXT") }

        let url = URL(string: "http://\(hostPart):\(port)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(message.utf8)
        request.timeoutInterval = max(timeout, 20)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return .posted
            }
            return .failed("bridge returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Continuous Bonjour browse for agent bridges, feeding the status screen.
/// `entries()` is an AsyncSequence of the current snapshot, re-emitted on
/// every change — the caller stores it into a `@Published` property.
@MainActor
final class AgentBridgeDiscovery: ObservableObject {

    struct Entry: Identifiable, Equatable {
        /// Bonjour instance name — the desktop registers with its machine
        /// name, so this is already human-readable. Kept as the stable
        /// identity for preferred-bridge selection.
        let id: String
        let name: String
        /// Machine name from the TXT `host=` record (nil for older bridges
        /// that don't advertise it).
        let host: String?
        /// TCP port from the TXT `port=` record (nil for older bridges).
        let port: UInt16?
        /// IPv4 address from the TXT `ip=` record — lets the phone skip
        /// all hostname resolution and connect directly.
        let ip: String?
        /// The NWEndpoint captured at browse time; it resolves lazily when a
        /// connection is opened against it (browse alone doesn't give the
        /// host/port — that's why the old row showed a bogus ":0").
        let endpoint: NWEndpoint

        /// What the status screen shows: machine name when we have it, else
        /// the raw instance name.
        var displayName: String { host ?? name }

        /// Human-readable endpoint for the status screen.
        var endpointText: String {
            if let ip, let port { return "\(displayName) · \(ip):\(port)" }
            if let port { return "\(displayName):\(port)" }
            return "\(displayName) · neoy bridge"
        }
    }

    private let emitter = Emitter()
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "neox.bridge.discover")

    nonisolated func entries() -> AsyncStream<[Entry]> {
        emitter.stream
    }

    func start() {
        guard browser == nil else { return }
        // bonjourWithTXTRecord delivers the TXT metadata alongside each browse
        // result — that's where the desktop's `host=` and `port=` records live.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: AgentBridge.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let entries: [Entry] = results.compactMap { result in
                guard case .service(let n, _, _, _) = result.endpoint else { return nil }
                var host: String?
                var port: UInt16?
                var ip: String?
                if case .bonjour(let txt) = result.metadata {
                    if case .string(let h)? = txt.getEntry(for: "host") { host = h }
                    if case .string(let p)? = txt.getEntry(for: "port") { port = UInt16(p) }
                    if case .string(let a)? = txt.getEntry(for: "ip") { ip = a }
                }
                return Entry(id: n, name: n, host: host, port: port, ip: ip,
                             endpoint: result.endpoint)
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
