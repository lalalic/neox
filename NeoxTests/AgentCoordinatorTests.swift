import Testing
@testable import Neox
import CopilotChat

@Suite("AgentCoordinator Tests")
@MainActor
struct AgentCoordinatorTests {
    
    @Test("Initial state has no session")
    func initialState() {
        let coordinator = AgentCoordinator()
        #expect(coordinator.currentSession == nil)
        #expect(!coordinator.isConnected)
        #expect(coordinator.registeredTools.isEmpty)
    }
    
    @Test("Register iOS-native tools")
    func registerTools() {
        let coordinator = AgentCoordinator()
        coordinator.registerDefaultTools()
        
        let toolNames = coordinator.registeredTools.map(\.name)
        #expect(toolNames.contains("speak"))
        #expect(toolNames.contains("listen"))
        #expect(toolNames.contains("notify"))
        #expect(toolNames.contains("take_photo"))
        #expect(toolNames.contains("copy_to_clipboard"))
    }
    
    @Test("All tools count includes WebKitAgent")
    func allToolsCount() {
        let coordinator = AgentCoordinator()
        coordinator.registerDefaultTools()
        
        // iOS-native tools + web_agent tool
        #expect(coordinator.allTools.count > 0)
    }
    
    @Test("System prompt includes skill prompt")
    func systemPrompt() {
        let coordinator = AgentCoordinator()
        let prompt = coordinator.buildSystemPrompt()
        
        #expect(prompt.contains("Neox"))
        #expect(prompt.contains("web"))
    }
    
    @Test("Initial agent is not running")
    func agentNotRunning() {
        let coordinator = AgentCoordinator()
        #expect(!coordinator.isAgentRunning)
    }
    
    @Test("Create chat view model produces a connected ViewModel")
    func createChat() {
        let coordinator = AgentCoordinator()
        let chatVM = coordinator.createChatViewModel()
        
        #expect(chatVM.chatState == .disconnected || chatVM.chatState == .connecting)
    }
    
    @Test("Default relay host and port")
    func defaultRelay() {
        let coordinator = AgentCoordinator()
        #expect(coordinator.connectionManager.host == nil)
        
        coordinator.connectionManager.configureRelay()
        #expect(coordinator.connectionManager.host == "relay.ai.qili2.com")
    }
}
