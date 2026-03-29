import Foundation
import Observation
import CopilotSDK

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

enum ConnectionError: Error, Equatable {
    case notConfigured
    case connectionFailed(String)
    case timeout
}

@Observable
@MainActor
final class ConnectionManager {
    var state: ConnectionState = .disconnected
    var host: String?
    var port: UInt16?
    private(set) var client: CopilotClient?
    
    func configure(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    
    func configureRelay() {
        configure(host: "relay.ai.qili2.com", port: 443)
    }
    
    func connect() async throws {
        guard let host, let port else {
            throw ConnectionError.notConfigured
        }
        
        state = .connecting
        
        let transport = WebSocketTransport(host: host, port: port)
        let copilotClient = CopilotClient(transport: transport)
        
        do {
            try await copilotClient.start()
            self.client = copilotClient
            state = .connected
        } catch {
            state = .disconnected
            throw ConnectionError.connectionFailed(error.localizedDescription)
        }
    }
    
    func disconnect() {
        client?.disconnect()
        client = nil
        state = .disconnected
    }
}
