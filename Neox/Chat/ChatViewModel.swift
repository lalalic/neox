import Foundation
import Observation

struct ChatMessage: Identifiable, Equatable {
    let id: String
    var role: Role
    var content: String
    var attachments: [Attachment]
    let timestamp: Date
    
    enum Role: Equatable {
        case user
        case assistant
        case system
    }
    
    init(id: String = UUID().uuidString, role: Role, content: String, attachments: [Attachment] = [], timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.timestamp = timestamp
    }
}

struct Attachment: Identifiable, Equatable {
    let id: String
    let type: AttachmentType
    
    init(id: String = UUID().uuidString, type: AttachmentType) {
        self.id = id
        self.type = type
    }
    
    static func == (lhs: Attachment, rhs: Attachment) -> Bool {
        lhs.id == rhs.id
    }
}

enum AttachmentType: Equatable {
    case image(data: Data, name: String)
    case document(data: Data, name: String, mimeType: String)
    
    static func == (lhs: AttachmentType, rhs: AttachmentType) -> Bool {
        switch (lhs, rhs) {
        case (.image(let d1, let n1), .image(let d2, let n2)):
            return d1 == d2 && n1 == n2
        case (.document(let d1, let n1, let m1), .document(let d2, let n2, let m2)):
            return d1 == d2 && n1 == n2 && m1 == m2
        default:
            return false
        }
    }
}

struct ActiveTool: Identifiable, Equatable {
    let id: String
    let name: String
    var status: ToolStatus
    
    enum ToolStatus: Equatable {
        case running
        case completed
        case failed
    }
}

struct TodoItem: Identifiable, Equatable {
    let id: Int
    var title: String
    var status: TodoStatus
    
    enum TodoStatus: String, Equatable {
        case notStarted = "not-started"
        case inProgress = "in-progress"
        case completed = "completed"
    }
}

@Observable
@MainActor
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText: String = ""
    var isProcessing: Bool = false
    var activeTools: [ActiveTool] = []
    var isWaitingForAnswer: Bool = false
    var todoItems: [TodoItem] = []
    var pendingAttachments: [Attachment] = []
    
    /// Callback invoked when user sends a message. Set by AgentCoordinator.
    var onSend: (@MainActor (String) -> Void)?
    
    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }
        
        let message = ChatMessage(role: .user, content: text, attachments: pendingAttachments)
        messages.append(message)
        inputText = ""
        pendingAttachments = []
        
        isProcessing = true
        isWaitingForAnswer = false
        
        onSend?(text)
        
        isProcessing = false
    }
    
    func receiveResponse(_ content: String) {
        let msg = ChatMessage(role: .assistant, content: content)
        messages.append(msg)
    }
    
    func receiveQuestion(_ question: String) {
        let msg = ChatMessage(role: .assistant, content: question)
        messages.append(msg)
        isWaitingForAnswer = true
    }
    
    func addMessage(_ message: ChatMessage) {
        messages.append(message)
    }
    
    func appendAssistantMessage(id: String) {
        let msg = ChatMessage(id: id, role: .assistant, content: "")
        messages.append(msg)
    }
    
    func appendDelta(_ delta: String, messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].content += delta
    }
    
    func showToolUse(name: String, status: ActiveTool.ToolStatus) {
        switch status {
        case .running:
            let tool = ActiveTool(id: UUID().uuidString, name: name, status: .running)
            activeTools.append(tool)
        case .completed, .failed:
            activeTools.removeAll { $0.name == name }
        }
    }
    
    func updateTodoList(_ items: [TodoItem]) {
        todoItems = items
    }
    
    func addAttachment(_ type: AttachmentType) {
        pendingAttachments.append(Attachment(type: type))
    }
    
    func removeAttachment(id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }
    
    // MARK: - Speech Input
    
    enum SpeechState: Equatable {
        case idle
        case listening
    }
    
    var speechState: SpeechState = .idle
    
    func toggleSpeech() {
        switch speechState {
        case .idle:
            speechState = .listening
        case .listening:
            speechState = .idle
        }
    }
    
    func appendSpeechTranscript(_ text: String) {
        inputText += text
    }
}
