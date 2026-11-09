import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatGatewayItem: Identifiable, Equatable {
    let id: String
    let kind: String
    let text: String
    let at: String
    let status: String?
    let level: String?
    let jobID: String?
    let repository: String?

    init(wire: [String: Any]) throws {
        guard let id = wire["id"] as? String, !id.isEmpty,
              let kind = wire["kind"] as? String,
              ["job", "report", "owner"].contains(kind),
              let text = wire["text"] as? String,
              let at = wire["at"] as? String else {
            throw ChatGatewayError.invalidItem
        }
        self.id = id
        self.kind = kind
        self.text = text
        self.at = at
        self.status = wire["status"] as? String
        self.level = wire["level"] as? String
        self.jobID = wire["jobId"] as? String
        self.repository = wire["repository"] as? String
    }

    var title: String {
        switch kind {
        case "owner": return "You"
        case "job": return "Job \(jobID ?? "") \(status ?? "")"
        default: return level == "attention" ? "Orchestrator · Attention" : "Orchestrator"
        }
    }

    var dateLabel: String {
        guard let value = ISO8601DateFormatter().date(from: at) else { return at }
        return value.formatted(date: .abbreviated, time: .shortened)
    }
}

enum ChatGatewayError: Error {
    case invalidItem
}

@MainActor
final class ChatGatewayStore: ObservableObject {
    @Published private(set) var items: [ChatGatewayItem] = []
    @Published private(set) var queued: [QueuedChatMessage] = []
    @Published var draft = ""

    private let outbox: ChatGatewayOutbox
    private var refreshing = false
    private var flushing = false

    init(outbox: ChatGatewayOutbox = ChatGatewayOutbox()) {
        self.outbox = outbox
        queued = outbox.messages
    }

    var visibleItems: [ChatGatewayItem] {
        let serverIDs = Set(items.map(\.id))
        let local = queued.filter { !serverIDs.contains("owner:" + $0.id) }
            .compactMap { pending -> ChatGatewayItem? in
                try? ChatGatewayItem(wire: [
                    "id": "owner:" + pending.id,
                    "kind": "owner",
                    "text": pending.text,
                    "at": ISO8601DateFormatter().string(from: pending.createdAt),
                    "status": "pending",
                ])
            }
        return (items + local).sorted { left, right in
            if left.at == right.at { return left.id < right.id }
            return left.at < right.at
        }
    }

    func refresh(from master: RemoteMCPClient) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        // The Chat screen is deliberately presentation-only. Connection,
        // credential discovery, account preparation, provisioning and retries
        // are owned by the phone client and Mac service, not UI instructions.
        guard master.hasConfiguredAddress && master.hasCredential else { return }
        if !master.connected { await master.connect() }
        guard master.connected else { return }

        do {
            items = try await master.chatGatewayFeed()
        } catch {
            // Preserve the last confirmed timeline; retry automatically.
        }
        do {
            if try await master.chatGatewayHeadBound() {
                await flush(using: master)
            }
        } catch {
            // An initializing/unreachable orchestrator is not a user error.
        }
    }

    func send(using master: RemoteMCPClient) async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 2000 else { return }

        // Commit locally BEFORE clearing the composer. A disconnected phone
        // or temporarily unavailable head never requires a Retry tap.
        do {
            try outbox.enqueue(message)
            queued = outbox.messages
            draft = ""
        } catch {
            // If local persistence fails, keep the draft intact, not a fake sent state.
            return
        }
        await refresh(from: master)
    }

    private func flush(using master: RemoteMCPClient) async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }

        for message in outbox.messages {
            do {
                try await master.sendChatGatewayMessage(message.text, requestID: message.id)
                try outbox.acknowledge(message.id)
                queued = outbox.messages
            } catch {
                // Preserve durable pending work and stable request ID; next
                // foreground/poll/reconnect retries without user intervention.
                return
            }
        }
        if !queued.isEmpty { return }
        if let latest = try? await master.chatGatewayFeed() { items = latest }
    }
}

struct ChatGatewayView: View {
    @ObservedObject var master: RemoteMCPClient
    @StateObject private var store = ChatGatewayStore()
    @StateObject private var dictation = ChatComposerDictation()
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var importingFile = false
    @State private var dictationPrefix = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        // An empty conversation stays empty. Never show network
                        // errors, connection notices, Retry, or "No messages".
                        ForEach(store.visibleItems) { item in
                            bubble(item).id(item.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .onChange(of: store.visibleItems.count) { _, _ in
                    if let last = store.visibleItems.last {
                        withAnimation { scroll.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            composer
        }
        .onChange(of: dictation.transcript) { _, text in
            guard !text.isEmpty else { return }
            let separator = dictationPrefix.isEmpty ||
                dictationPrefix.hasSuffix(" ") || dictationPrefix.hasSuffix("\n") ? "" : " "
            store.draft = String((dictationPrefix + separator + text).prefix(2000))
        }
        .onChange(of: pickedPhoto) { photo in
            guard let photo else { return }
            Task {
                if let text = try? await ChatComposerImport.textFromPhoto(photo) {
                    store.draft = ChatComposerImport.append(text, to: store.draft, source: "Photo text")
                    if !text.isEmpty { composerFocused = true }
                }
                pickedPhoto = nil
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.text, .pdf]) { result in
            guard case .success(let url) = result else { return }
            if let text = try? ChatComposerImport.textFromFile(url) {
                store.draft = ChatComposerImport.append(text, to: store.draft, source: url.lastPathComponent)
                if !text.isEmpty { composerFocused = true }
            }
        }
        .onDisappear { dictation.stop() }
        .task {
            // Automatic recovery while the Chat tab is visible.
            while !Task.isCancelled {
                await store.refresh(from: master)
                do { try await Task.sleep(for: .seconds(8)) }
                catch { return }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("Message", text: $store.draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...5)
                .font(.body)
                .accessibilityIdentifier("neoChatComposer")

            HStack(spacing: 12) {
                Menu {
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("Text from Photo", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        importingFile = true
                    } label: {
                        Label("Text from File", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("neoChatAdd")

                Spacer(minLength: 0)

                Button {
                    if !dictation.isRecording && !dictation.isStarting {
                        dictationPrefix = store.draft
                        composerFocused = false
                    }
                    dictation.toggle()
                } label: {
                    Image(systemName: dictation.isRecording ? "stop.fill" : "mic")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.primary)
                        .frame(width: 35, height: 35)
                        .contentShape(Circle())
                }
                .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                .accessibilityIdentifier("neoChatMicrophone")

                Button {
                    dictation.stop()
                    Task { await store.send(using: master) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 34, height: 34)
                        .background(Color(uiColor: .label), in: Circle())
                }
                .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          store.draft.count > 2000)
                .opacity(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("neoChatSend")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private func bubble(_ item: ChatGatewayItem) -> some View {
        HStack {
            if item.kind == "owner" { Spacer(minLength: 55) }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(item.text)
                    .textSelection(.enabled)
                    .font(.body)
                Text(item.dateLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(item.kind == "owner" ? Color.accentColor.opacity(0.14) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(item.status == "pending" ? 0.65 : 1.0)
            .accessibilityIdentifier("neoChatMessage")
            if item.kind != "owner" { Spacer(minLength: 55) }
        }
    }
}
