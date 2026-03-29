import Testing
import Foundation
@testable import Neox

@Suite("ChatViewModel Tests")
@MainActor
struct ChatViewModelTests {
    
    @Test("Initial state has no messages")
    func initialState() {
        let vm = ChatViewModel()
        #expect(vm.messages.isEmpty)
        #expect(vm.inputText == "")
        #expect(!vm.isProcessing)
    }
    
    @Test("Send adds user message")
    func sendAddsUserMessage() async {
        let vm = ChatViewModel()
        vm.inputText = "Hello agent"
        await vm.send()
        
        #expect(vm.messages.count >= 1)
        #expect(vm.messages.first?.role == .user)
        #expect(vm.messages.first?.content == "Hello agent")
        #expect(vm.inputText == "") // cleared after send
    }
    
    @Test("Send sets processing state")
    func sendSetsProcessing() async {
        let vm = ChatViewModel()
        vm.inputText = "Hello"
        
        await vm.send()
        
        #expect(!vm.isProcessing)
    }
    
    @Test("Empty input does not send")
    func emptyInputNoSend() async {
        let vm = ChatViewModel()
        vm.inputText = ""
        await vm.send()
        
        #expect(vm.messages.isEmpty)
    }
    
    @Test("Whitespace-only input does not send")
    func whitespaceOnlyNoSend() async {
        let vm = ChatViewModel()
        vm.inputText = "   \n  "
        await vm.send()
        
        #expect(vm.messages.isEmpty)
    }
    
    @Test("Append delta to last assistant message")
    func appendDelta() {
        let vm = ChatViewModel()
        vm.appendAssistantMessage(id: "msg1")
        vm.appendDelta("Hello ", messageId: "msg1")
        vm.appendDelta("world!", messageId: "msg1")
        
        let lastMsg = vm.messages.last
        #expect(lastMsg?.role == .assistant)
        #expect(lastMsg?.content == "Hello world!")
    }
    
    @Test("Show tool use indicator")
    func toolUseIndicator() {
        let vm = ChatViewModel()
        vm.showToolUse(name: "web_agent", status: .running)
        
        #expect(vm.activeTools.count == 1)
        #expect(vm.activeTools.first?.name == "web_agent")
        
        vm.showToolUse(name: "web_agent", status: .completed)
        #expect(vm.activeTools.isEmpty)
    }
    
    @Test("Messages are ordered chronologically")
    func messageOrdering() {
        let vm = ChatViewModel()
        vm.addMessage(ChatMessage(role: .user, content: "First"))
        vm.addMessage(ChatMessage(role: .assistant, content: "Second"))
        vm.addMessage(ChatMessage(role: .user, content: "Third"))
        
        #expect(vm.messages.count == 3)
        #expect(vm.messages[0].content == "First")
        #expect(vm.messages[1].content == "Second")
        #expect(vm.messages[2].content == "Third")
    }
    
    @Test("onSend callback is invoked with user text")
    func onSendCallback() async {
        let vm = ChatViewModel()
        var captured: String?
        vm.onSend = { text in captured = text }
        
        vm.inputText = "Test message"
        await vm.send()
        
        #expect(captured == "Test message")
    }
    
    @Test("receiveResponse adds assistant message")
    func receiveResponse() {
        let vm = ChatViewModel()
        vm.receiveResponse("Hello from agent")
        
        #expect(vm.messages.count == 1)
        #expect(vm.messages.last?.role == .assistant)
        #expect(vm.messages.last?.content == "Hello from agent")
    }
    
    @Test("receiveQuestion shows agent question")
    func receiveQuestion() {
        let vm = ChatViewModel()
        vm.receiveQuestion("What should I do next?")
        
        #expect(vm.messages.count == 1)
        #expect(vm.messages.last?.role == .assistant)
        #expect(vm.messages.last?.content == "What should I do next?")
        #expect(vm.isWaitingForAnswer)
    }
    
    // MARK: - Todo List Tests
    
    @Test("Initial state has empty todo list")
    func initialTodoList() {
        let vm = ChatViewModel()
        #expect(vm.todoItems.isEmpty)
    }
    
    @Test("Update todo list replaces items")
    func updateTodoList() {
        let vm = ChatViewModel()
        let items = [
            TodoItem(id: 1, title: "First task", status: .notStarted),
            TodoItem(id: 2, title: "Second task", status: .inProgress)
        ]
        vm.updateTodoList(items)
        
        #expect(vm.todoItems.count == 2)
        #expect(vm.todoItems[0].title == "First task")
        #expect(vm.todoItems[1].status == .inProgress)
    }
    
    @Test("Todo item status transitions")
    func todoStatusTransitions() {
        let vm = ChatViewModel()
        vm.updateTodoList([
            TodoItem(id: 1, title: "Task A", status: .notStarted),
            TodoItem(id: 2, title: "Task B", status: .inProgress),
            TodoItem(id: 3, title: "Task C", status: .completed)
        ])
        
        #expect(vm.todoItems[0].status == .notStarted)
        #expect(vm.todoItems[1].status == .inProgress)
        #expect(vm.todoItems[2].status == .completed)
    }
    
    @Test("Todo list update replaces previous items")
    func todoListReplace() {
        let vm = ChatViewModel()
        vm.updateTodoList([TodoItem(id: 1, title: "Old", status: .notStarted)])
        vm.updateTodoList([TodoItem(id: 1, title: "New", status: .completed)])
        
        #expect(vm.todoItems.count == 1)
        #expect(vm.todoItems[0].title == "New")
        #expect(vm.todoItems[0].status == .completed)
    }
    
    // MARK: - Attachment Tests
    
    @Test("Initial state has no pending attachments")
    func initialAttachments() {
        let vm = ChatViewModel()
        #expect(vm.pendingAttachments.isEmpty)
    }
    
    @Test("Add image attachment")
    func addImageAttachment() {
        let vm = ChatViewModel()
        let data = Data([0xFF, 0xD8, 0xFF]) // JPEG header stub
        vm.addAttachment(.image(data: data, name: "photo.jpg"))
        
        #expect(vm.pendingAttachments.count == 1)
        if case .image(_, let name) = vm.pendingAttachments[0].type {
            #expect(name == "photo.jpg")
        } else {
            Issue.record("Expected image attachment")
        }
    }
    
    @Test("Add document attachment")
    func addDocAttachment() {
        let vm = ChatViewModel()
        let data = Data("Hello PDF".utf8)
        vm.addAttachment(.document(data: data, name: "doc.pdf", mimeType: "application/pdf"))
        
        #expect(vm.pendingAttachments.count == 1)
        if case .document(_, let name, let mime) = vm.pendingAttachments[0].type {
            #expect(name == "doc.pdf")
            #expect(mime == "application/pdf")
        } else {
            Issue.record("Expected document attachment")
        }
    }
    
    @Test("Remove pending attachment")
    func removeAttachment() {
        let vm = ChatViewModel()
        vm.addAttachment(.image(data: Data(), name: "a.jpg"))
        vm.addAttachment(.image(data: Data(), name: "b.jpg"))
        
        let idToRemove = vm.pendingAttachments[0].id
        vm.removeAttachment(id: idToRemove)
        
        #expect(vm.pendingAttachments.count == 1)
        if case .image(_, let name) = vm.pendingAttachments[0].type {
            #expect(name == "b.jpg")
        }
    }
    
    @Test("Send clears pending attachments and attaches to message")
    func sendWithAttachments() async {
        let vm = ChatViewModel()
        vm.addAttachment(.image(data: Data([1, 2, 3]), name: "pic.jpg"))
        vm.inputText = "Check this image"
        await vm.send()
        
        #expect(vm.pendingAttachments.isEmpty)
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].attachments.count == 1)
        #expect(vm.messages[0].content == "Check this image")
    }
    
    @Test("Send with only attachment and no text")
    func sendAttachmentOnly() async {
        let vm = ChatViewModel()
        vm.addAttachment(.image(data: Data([1]), name: "img.png"))
        vm.inputText = ""
        await vm.send()
        
        // Should still send when there's an attachment even without text
        #expect(vm.messages.count == 1)
        #expect(vm.messages[0].attachments.count == 1)
        #expect(vm.messages[0].content.isEmpty)
    }
    
    @Test("Message without attachments has empty array")
    func messageNoAttachments() {
        let msg = ChatMessage(role: .user, content: "Hello")
        #expect(msg.attachments.isEmpty)
    }
    
    // MARK: - Speech Input Tests
    
    @Test("Initial speech state is idle")
    func speechInitialState() {
        let vm = ChatViewModel()
        #expect(vm.speechState == .idle)
    }
    
    @Test("Toggle speech starts listening when idle")
    func toggleSpeechStartsListening() {
        let vm = ChatViewModel()
        vm.toggleSpeech()
        #expect(vm.speechState == .listening)
    }
    
    @Test("Toggle speech stops when listening")
    func toggleSpeechStops() {
        let vm = ChatViewModel()
        vm.toggleSpeech() // start
        #expect(vm.speechState == .listening)
        vm.toggleSpeech() // stop
        #expect(vm.speechState == .idle)
    }
    
    @Test("Append speech transcript updates input text")
    func appendSpeechTranscript() {
        let vm = ChatViewModel()
        vm.appendSpeechTranscript("Hello world")
        #expect(vm.inputText == "Hello world")
    }
    
    @Test("Append speech transcript appends to existing text")
    func appendSpeechTranscriptAppends() {
        let vm = ChatViewModel()
        vm.inputText = "Already here: "
        vm.appendSpeechTranscript("more words")
        #expect(vm.inputText == "Already here: more words")
    }
}
