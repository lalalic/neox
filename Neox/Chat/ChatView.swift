import SwiftUI
import PhotosUI
import AppAgent

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(message: message)
                        }
                        
                        // Show active tool processing
                        ForEach(viewModel.activeTools) { tool in
                            ToolProcessingView(tool: tool)
                        }
                    }
                    .padding()
                }
                
                // Todo list above input
                if !viewModel.todoItems.isEmpty {
                    TodoListView(items: viewModel.todoItems)
                }
                
                InputBar(
                    text: $viewModel.inputText,
                    isProcessing: viewModel.isProcessing,
                    pendingAttachments: viewModel.pendingAttachments,
                    speechState: viewModel.speechState,
                    onSend: { Task { await viewModel.send() } },
                    onAddAttachment: { viewModel.addAttachment($0) },
                    onRemoveAttachment: { viewModel.removeAttachment(id: $0) },
                    onToggleSpeech: { viewModel.toggleSpeech() },
                    onSpeechTranscript: { viewModel.appendSpeechTranscript($0) }
                )
            }
            .navigationTitle("Neox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        let setup = AppAgentSetup.shared
                        if let err = setup.startError {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        } else {
                            Text(setup.bridgeState != "off" ? "bridge:\(setup.bridgeState)" : setup.serverState)
                                .font(.caption2)
                                .foregroundStyle(setup.isRunning || setup.bridgeState == "connected" ? .green : .secondary)
                        }
                        Circle()
                            .fill(setup.isRunning || setup.bridgeState == "connected" ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
    }
}

struct ToolProcessingView: View {
    let tool: ActiveTool
    
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text(tool.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TodoListView: View {
    let items: [TodoItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: item.status))
                        .font(.caption)
                        .foregroundStyle(iconColor(for: item.status))
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(item.status == .completed ? .secondary : .primary)
                        .strikethrough(item.status == .completed)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6).opacity(0.5))
    }
    
    private func iconName(for status: TodoItem.TodoStatus) -> String {
        switch status {
        case .notStarted: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        }
    }
    
    private func iconColor(for status: TodoItem.TodoStatus) -> Color {
        switch status {
        case .notStarted: .secondary
        case .inProgress: .blue
        case .completed: .green
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.role == .user { Spacer() }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                ForEach(message.attachments) { attachment in
                    AttachmentView(attachment: attachment, isUser: message.role == .user)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .foregroundStyle(message.role == .user ? .white : .primary)
                }
            }
            .padding(12)
            .background(message.role == .user ? Color.blue : Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            
            if message.role == .assistant { Spacer() }
        }
    }
}

struct AttachmentView: View {
    let attachment: Attachment
    let isUser: Bool
    
    var body: some View {
        switch attachment.type {
        case .image(let data, _):
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        case .document(_, let name, _):
            HStack(spacing: 6) {
                Image(systemName: "doc.fill")
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(isUser ? .white : .primary)
        }
    }
}

struct InputBar: View {
    @Binding var text: String
    let isProcessing: Bool
    let pendingAttachments: [Attachment]
    let speechState: ChatViewModel.SpeechState
    let onSend: () -> Void
    let onAddAttachment: (AttachmentType) -> Void
    let onRemoveAttachment: (String) -> Void
    let onToggleSpeech: () -> Void
    let onSpeechTranscript: (String) -> Void
    
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showDocumentPicker = false
    @State private var speechRecognizer = SpeechRecognizer()
    
    var body: some View {
        VStack(spacing: 0) {
            // Pending attachments preview
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            PendingAttachmentThumb(attachment: attachment) {
                                onRemoveAttachment(attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .background(Color(.systemGray6).opacity(0.5))
            }
            
            HStack(spacing: 8) {
                // Photo picker
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 5, matching: .images) {
                    Image(systemName: "photo")
                        .font(.title3)
                }
                .accessibilityLabel("Add photo")
                .onChange(of: selectedPhotos) { _, items in
                    Task { await loadPhotos(items) }
                    selectedPhotos = []
                }
                
                // Document picker
                Button { showDocumentPicker = true } label: {
                    Image(systemName: "doc")
                        .font(.title3)
                }
                .accessibilityLabel("Add document")
                
                TextField("Ask Neox...", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel("Message input")
                
                // Microphone button
                Button(action: {
                    if speechState == .idle {
                        // Starting recording
                        speechRecognizer.onTranscript = { transcript in
                            onSpeechTranscript(transcript)
                        }
                        speechRecognizer.start()
                    } else {
                        // Stopping recording
                        speechRecognizer.stop()
                    }
                    onToggleSpeech()
                }) {
                    Image(systemName: speechState == .listening ? "mic.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(speechState == .listening ? .red : .primary)
                }
                .accessibilityLabel(speechState == .listening ? "Stop listening" : "Start listening")
                
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty) || isProcessing)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { url in
                loadDocument(url)
            }
        }
    }
    
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let name = "photo_\(UUID().uuidString.prefix(6)).jpg"
                onAddAttachment(.image(data: data, name: name))
            }
        }
    }
    
    private func loadDocument(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        let mime = mimeType(for: url.pathExtension)
        onAddAttachment(.document(data: data, name: name, mimeType: mime))
    }
    
    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: "application/octet-stream"
        }
    }
}

struct PendingAttachmentThumb: View {
    let attachment: Attachment
    let onRemove: () -> Void
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch attachment.type {
                case .image(let data, _):
                    if let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                case .document(_, let name, _):
                    VStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .font(.title3)
                        Text(name)
                            .font(.system(size: 8))
                            .lineLimit(1)
                    }
                    .frame(width: 60, height: 60)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, .gray)
            }
            .offset(x: 4, y: -4)
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.forEach { onPick($0) }
        }
    }
}
