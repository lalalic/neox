import Foundation
import Network

/// Private loopback HTTP sidecar for file data; never exposes a second public endpoint.
/// NeoY remains the only external gateway and continues to own mount configuration.
final class NeoYRustFileSidecar: @unchecked Sendable {
    let port: UInt16
    let token: String
    private let child: Process

    init?(staticRoot: URL?) {
        if ProcessInfo.processInfo.environment["NEOY_FILE_SERVER_BACKEND"] == "swift" { return nil }
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("neoy-file-server"),
              FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
        port = UInt16.random(in: 19000...59000)
        token = UUID().uuidString + UUID().uuidString
        child = Process()
        child.executableURL = binary
        var arguments = [
            "--port", String(port),
            "--mounts", NeoYFileMounts.configURL.path
        ]
        if let staticRoot { arguments += ["--static-root", staticRoot.path] }
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NEO_CORE_FULL_ACCESS_ACK")
        environment.removeValue(forKey: "CONTROL_PLANE_API_KEY")
        environment["NEOY_FILE_SERVER_TOKEN"] = token
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { completed in
            NSLog("NeoY Rust file server exited (status %d)", completed.terminationStatus)
        }
        do { try child.run() }
        catch {
            NSLog("NeoY Rust file server unavailable: %@", error.localizedDescription)
            return nil
        }
    }

    var isRunning: Bool { child.isRunning }

    deinit {
        if child.isRunning { child.terminate() }
    }

    func stop() {
        if child.isRunning { child.terminate() }
    }

    /// A streaming reverse proxy, not buffering media in Swift. Every read waits
    /// for its previous 64 KiB send completion (explicit downstream backpressure).
    /// If the Rust process cannot answer at all, use the current Swift handler.
    func forward(method: String, path: String, requestHeaders: [String: String],
                 client: NWConnection, queue: DispatchQueue, fallback: @escaping @Sendable () -> Void) -> Bool {
        guard child.isRunning, let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let upstream = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        let progress = FileForwardProgress()
        upstream.stateUpdateHandler = { status in
            switch status {
            case .ready:
                var request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Neo-File-Token: \(self.token)\r\nConnection: close\r\n"
                // Forward only file-transfer cache/range semantics, never client
                // credentials or arbitrary hop-by-hop/request-control headers.
                for name in ["range", "if-none-match", "if-modified-since", "if-range",
                             "if-match", "if-unmodified-since"] {
                    if let value = requestHeaders[name], value.utf8.count < 4096,
                       !value.contains("\r"), !value.contains("\n") {
                        request += "\(name): \(value)\r\n"
                    }
                }
                request += "\r\n"
                upstream.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if error != nil {
                        Self.finish(upstream: upstream, client: client, progress: progress, fallback: fallback)
                    } else {
                        Self.receive(upstream: upstream, client: client, progress: progress, fallback: fallback)
                    }
                })
            case .failed:
                Self.finish(upstream: upstream, client: client, progress: progress, fallback: fallback)
            default: break
            }
        }
        upstream.start(queue: queue)
        return true
    }

    nonisolated private static func receive(upstream: NWConnection, client: NWConnection,
                                            progress: FileForwardProgress,
                                            fallback: @escaping @Sendable () -> Void) {
        upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            if let data, !data.isEmpty {
                progress.markResponse()
                client.send(content: data, completion: .contentProcessed { sendError in
                    if error != nil || sendError != nil || complete {
                        Self.finish(upstream: upstream, client: client, progress: progress, fallback: fallback)
                    } else {
                        Self.receive(upstream: upstream, client: client, progress: progress, fallback: fallback)
                    }
                })
            } else if error != nil || complete {
                Self.finish(upstream: upstream, client: client, progress: progress, fallback: fallback)
            } else {
                Self.receive(upstream: upstream, client: client, progress: progress, fallback: fallback)
            }
        }
    }

    nonisolated private static func finish(upstream: NWConnection, client: NWConnection,
                                           progress: FileForwardProgress,
                                           fallback: @escaping @Sendable () -> Void) {
        let action = progress.finish()
        upstream.cancel()
        switch action {
        case .fallback: fallback()
        case .close: client.cancel()
        case .alreadyClosed: break
        }
    }
}

/// The only mutable state shared by connection-completion callbacks.
private final class FileForwardProgress: @unchecked Sendable {
    enum End { case fallback, close, alreadyClosed }
    private let lock = NSLock()
    private var responseStarted = false
    private var finished = false

    func markResponse() {
        lock.lock(); defer { lock.unlock() }
        responseStarted = true
    }
    func finish() -> End {
        lock.lock(); defer { lock.unlock() }
        if finished { return .alreadyClosed }
        finished = true
        return responseStarted ? .close : .fallback
    }
}
