import Testing
import Foundation
@testable import Neox
import CopilotSDK
import CopilotChat

// MARK: - Mock Transport

/// Minimal mock transport for unit tests — never actually connects.
final class MockTransport: Transport, @unchecked Sendable {
    func connect() async throws {}
    func disconnect() {}
    func send(_ data: Data) async throws {}
    func receive() -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Test Helpers

/// Create a ChatViewModel with mock transport for testing.
@MainActor
func makeTestVM() -> ChatViewModel {
    let transport = MockTransport()
    let config = AgentConfig(
        instructions: "You are a test agent.",
        tools: [],
        onResponse: { _ in },
        onAskUser: { _ in "" }
    )
    // Use a unique UserDefaults suite so tests don't read persisted data
    let testDefaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    let tracker = UsageTracker(defaults: testDefaults)
    return ChatViewModel(transport: transport, mode: .agent(config), usageTracker: tracker)
}

// MARK: - Tests

@Suite("ChatViewModel Tests")
@MainActor
struct ChatViewModelTests {

    @Test("Initial state has no messages")
    func initialState() {
        let vm = makeTestVM()
        #expect(vm.messages.isEmpty)
        #expect(vm.inputText == "")
        #expect(vm.chatState == .disconnected)
    }

    @Test("Empty input does not send")
    func emptyInputNoSend() async {
        let vm = makeTestVM()
        vm.inputText = ""
        await vm.send()

        #expect(vm.messages.isEmpty)
    }

    @Test("Whitespace-only input does not send")
    func whitespaceOnlyNoSend() async {
        let vm = makeTestVM()
        vm.inputText = "   \n  "
        await vm.send()

        #expect(vm.messages.isEmpty)
    }

    @Test("Send appends user message and clears input")
    func sendAppendsMessage() async {
        let vm = makeTestVM()
        vm.inputText = "Hello agent"
        await vm.send()

        #expect(vm.inputText == "")
        #expect(vm.messages.count >= 1)
        #expect(vm.messages.first?.role == .user)
    }

    @Test("ChatMessage user role construction")
    func chatMessageConstruction() {
        let msg = ChatMessage(role: .user, content: [.text("Hello")])
        #expect(msg.role == .user)
        #expect(msg.content.count == 1)
        if case .text(let text) = msg.content.first {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text content block")
        }
    }

    @Test("ChatMessage assistant role construction")
    func assistantMessage() {
        let msg = ChatMessage(role: .assistant, content: [.text("Hi there")])
        #expect(msg.role == .assistant)
    }

    @Test("ChatMessage with multiple content blocks")
    func multiBlockMessage() {
        let msg = ChatMessage(role: .assistant, content: [
            .text("Here's some code:"),
            .code("print('hello')", language: "python"),
            .text("Done!")
        ])
        #expect(msg.content.count == 3)
    }

    @Test("ChatState equality")
    func chatStateEquality() {
        #expect(ChatState.disconnected == .disconnected)
        #expect(ChatState.idle == .idle)
        #expect(ChatState.working == .working)
        #expect(ChatState.connecting == .connecting)
    }

    // MARK: - Todo List Tests

    @Test("Initial state has empty todo list")
    func initialTodoList() {
        let vm = makeTestVM()
        #expect(vm.todoItems.isEmpty)
    }

    @Test("TodoItem construction and status")
    func todoItemConstruction() {
        let item = TodoItem(id: 1, title: "Write tests", status: .notStarted)
        #expect(item.id == 1)
        #expect(item.title == "Write tests")
        #expect(item.status == .notStarted)
        #expect(item.statusIcon == "○")
    }

    @Test("TodoItem status icons")
    func todoStatusIcons() {
        let notStarted = TodoItem(id: 1, title: "A", status: .notStarted)
        let inProgress = TodoItem(id: 2, title: "B", status: .inProgress)
        let completed = TodoItem(id: 3, title: "C", status: .completed)

        #expect(notStarted.statusIcon == "○")
        #expect(inProgress.statusIcon == "●")
        #expect(completed.statusIcon == "✓")
    }

    @Test("TodoItem equality")
    func todoEquality() {
        let a = TodoItem(id: 1, title: "Task", status: .notStarted)
        let b = TodoItem(id: 1, title: "Task", status: .notStarted)
        #expect(a == b)
    }

    // MARK: - Attachment Store Tests

    @Test("Initial attachment store has no prompt description")
    func initialAttachments() {
        let vm = makeTestVM()
        #expect(vm.attachmentStore.promptDescription() == nil)
    }

    // MARK: - Disconnect Tests

    @Test("Disconnect resets state")
    func disconnectResetsState() {
        let vm = makeTestVM()
        vm.disconnect()
        #expect(vm.chatState == .disconnected)
    }

    // MARK: - Input Modes

    @Test("Default input modes include text and speech")
    func defaultInputModes() {
        let vm = makeTestVM()
        #expect(vm.inputModes.contains(.text))
        #expect(vm.inputModes.contains(.speech))
    }

    // MARK: - Usage Tracker

    @Test("Usage tracker starts with zero")
    func usageTrackerInitial() {
        let vm = makeTestVM()
        #expect(vm.usageTracker.sessionTokens == 0)
        #expect(vm.usageTracker.sessionCost == 0.0)
        #expect(vm.usageTracker.lifetimeTokens == 0)
    }

    // MARK: - Plan Store

    @Test("Plan store starts empty")
    func planStoreInitial() {
        let vm = makeTestVM()
        #expect(vm.planStore.plans.isEmpty)
    }

    // MARK: - Ask Questions

    @Test("Active questions initially empty")
    func activeQuestionsEmpty() {
        let vm = makeTestVM()
        #expect(vm.activeQuestions.isEmpty)
    }

    // MARK: - Message Content Block

    @Test("Text content block")
    func textContentBlock() {
        let block = ChatMessage.ContentBlock.text("Hello")
        if case .text(let text) = block {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text block")
        }
    }

    @Test("Code content block")
    func codeContentBlock() {
        let block = ChatMessage.ContentBlock.code("let x = 1", language: "swift")
        if case .code(let code, let lang) = block {
            #expect(code == "let x = 1")
            #expect(lang == "swift")
        } else {
            Issue.record("Expected code block")
        }
    }

    @Test("Image content block")
    func imageContentBlock() {
        let data = Data([0xFF, 0xD8, 0xFF])
        let block = ChatMessage.ContentBlock.image(data, mimeType: "image/jpeg")
        if case .image(let imageData, let mime) = block {
            #expect(imageData == data)
            #expect(mime == "image/jpeg")
        } else {
            Issue.record("Expected image block")
        }
    }
}
