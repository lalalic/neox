import Testing
@testable import Neox

@Suite("ConnectionManager Tests")
@MainActor
struct ConnectionManagerTests {
    
    @Test("Initial state is disconnected")
    func initialState() {
        let manager = ConnectionManager()
        #expect(manager.state == .disconnected)
        #expect(manager.host == nil)
        #expect(manager.port == nil)
    }
    
    @Test("Configure sets host and port")
    func configure() {
        let manager = ConnectionManager()
        manager.configure(host: "192.168.1.100", port: 8080)
        #expect(manager.host == "192.168.1.100")
        #expect(manager.port == 8080)
    }
    
    @Test("Default relay configuration")
    func defaultRelay() {
        let manager = ConnectionManager()
        manager.configureRelay()
        #expect(manager.host == "relay.ai.qili2.com")
        #expect(manager.port == 443)
    }
    
    @Test("State transitions to connecting on connect")
    func connectTransition() async {
        let manager = ConnectionManager()
        manager.configure(host: "192.168.1.100", port: 8080)
        
        let task = Task {
            try await manager.connect()
        }
        
        try? await Task.sleep(for: .milliseconds(100))
        #expect(manager.state == .connecting)
        
        task.cancel()
    }
    
    @Test("Cannot connect without configuration")
    func connectWithoutConfig() async throws {
        let manager = ConnectionManager()
        
        await #expect(throws: ConnectionError.notConfigured) {
            try await manager.connect()
        }
    }
    
    @Test("Disconnect returns to disconnected state")
    func disconnect() {
        let manager = ConnectionManager()
        manager.configure(host: "192.168.1.100", port: 8080)
        manager.disconnect()
        #expect(manager.state == .disconnected)
    }
    
    @Test("Client is nil before connect")
    func clientNilBeforeConnect() {
        let manager = ConnectionManager()
        #expect(manager.client == nil)
    }
}
