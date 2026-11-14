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

    var dateLabel: String { smartDateLabel() }

    func smartDateLabel(relativeTo now: Date = Date(), calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: at) ?? {
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: at)
        }() else { return at }
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInYesterday(date) && calendar.isDate(now, inSameDayAs: Date()) {
            return "Yesterday · " + time
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday · " + time
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day,
           (2...6).contains(days) {
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date) + " · " + time
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        }
        return formatter.string(from: date) + " · " + time
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
    @Published var draftAttachments: [ChatLocalAttachment] = []
    @Published private(set) var clearedAt: Date?

    private let preferences: UserDefaults
    private static let historyClearKey = "neo.chat.history.hidden-before.v1"
    private let outbox: ChatGatewayOutbox
    private var refreshing = false
    private var flushing = false

    init(outbox: ChatGatewayOutbox = ChatGatewayOutbox(), preferences: UserDefaults = .standard) {
        self.outbox = outbox
        self.preferences = preferences
        clearedAt = preferences.object(forKey: Self.historyClearKey) as? Date
        queued = outbox.messages
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-neo-chat-rich-fixture") {
            let hash = String(repeating: "a", count: 64)
            let sample = """
            **Summary**: Agent reports using `chat_report`.

            ```mermaid
            flowchart LR
            Mobile[Neo Mobile] --> Gateway[Chat Gateway]
            Gateway --> Agent
            Agent -->|chat_report| Mobile
            ```

            [Markcut video preview](markcut://preview/\(hash))
            """
            items = [try! ChatGatewayItem(wire: [
                "id":"report:chat-markup-fixture", "kind":"report", "text":sample,
                "level":"info", "at":ISO8601DateFormatter().string(from: Date()),
            ])]
        }
        #endif
    }

    /// Hide old timeline entries on this phone only. Never mutate the Mac's
    /// durable feed or discard unsent outbox messages and attachments.
    func clearVisibleHistory(at time: Date = Date()) {
        clearedAt = time
        preferences.set(time, forKey: Self.historyClearKey)
    }

    private func isVisibleSinceClear(_ item: ChatGatewayItem) -> Bool {
        guard let clearedAt else { return true }
        let parser = ISO8601DateFormatter()
        guard let timestamp = parser.date(from: item.at) ?? {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: item.at)
        }() else { return false }
        return timestamp > clearedAt
    }

    var visibleItems: [ChatGatewayItem] {
        let serverIDs = Set(items.map(\.id))
        let local = queued.filter { !serverIDs.contains("owner:" + $0.id) }
            .compactMap { pending -> ChatGatewayItem? in
                try? ChatGatewayItem(wire: [
                    "id": "owner:" + pending.id,
                    "kind": "owner",
                    "text": pending.text + (pending.attachments ?? []).map { "\n📎 " + $0.name }.joined(),
                    "at": ISO8601DateFormatter().string(from: pending.createdAt),
                    "status": "pending",
                ])
            }
        return (items + local).filter(isVisibleSinceClear).sorted { left, right in
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

    func send(using master: RemoteMCPClient) -> Bool {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!message.isEmpty || !draftAttachments.isEmpty), message.count <= 2000 else { return false }

        // Commit locally BEFORE clearing the composer. A disconnected phone
        // or temporarily unavailable head never requires a Retry tap.
        do {
            try outbox.enqueue(message, attachments: draftAttachments)
            queued = outbox.messages
            draft = ""
            draftAttachments = []
        } catch {
            // If local persistence fails, keep the draft intact, not a fake sent state.
            return false
        }
        // Start delivery immediately, but do not keep the composer focused
        // while a gateway request is in flight.
        Task { await refresh(from: master) }
        return true
    }

    func attach(data: Data, name: String) {
        guard draftAttachments.count < 4,
              let stored = try? outbox.stage(data, name: name) else { return }
        draftAttachments.append(stored)
    }

    func attach(fileURL: URL) {
        guard draftAttachments.count < 4,
              let stored = try? outbox.stage(fileURL: fileURL) else { return }
        draftAttachments.append(stored)
    }

    func removeAttachment(_ attachment: ChatLocalAttachment) {
        draftAttachments.removeAll { $0.id == attachment.id }
        outbox.discard(attachment)
    }

    private func flush(using master: RemoteMCPClient) async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }

        for message in outbox.messages {
            do {
                try await master.sendChatGatewayMessage(
                    message.text, requestID: message.id, attachments: message.attachments ?? [])
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
    let isActive: Bool
    @StateObject private var store = ChatGatewayStore()
    @StateObject private var dictation = ChatComposerDictation()
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var importingFile = false
    @State private var dictationPrefix = ""
    @State private var showClearHistoryConfirmation = false
    @State private var selectedMarkcut: ChatMarkcutReference?
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
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
                .onChange(of: store.visibleItems.count) { _, _ in
                    if let last = store.visibleItems.last {
                        withAnimation { scroll.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            composer
        }
        .sheet(item: $selectedMarkcut) { reference in
            ChatMarkcutPreviewSheet(master: master, hash: reference.hash)
        }
        .confirmationDialog("Clear chat messages on this phone?", isPresented: $showClearHistoryConfirmation,
                            titleVisibility: .visible) {
            Button("Clear displayed history", role: .destructive) {
                store.clearVisibleHistory()
            }
            .accessibilityIdentifier("neoChatConfirmClear")
        } message: {
            Text("This hides old messages in Neo Mobile. It does not delete Neo Master history or cancel queued messages.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { composerFocused = false }
            }
        }
        .onChange(of: dictation.transcript) { _, text in
            guard !text.isEmpty else { return }
            let separator = dictationPrefix.isEmpty ||
                dictationPrefix.hasSuffix(" ") || dictationPrefix.hasSuffix("\n") ? "" : " "
            store.draft = String((dictationPrefix + separator + text).prefix(2000))
        }
        .onChange(of: isActive) { _, active in
            if !active {
                dictation.stop()
                composerFocused = false
            }
        }
        .onChange(of: pickedPhoto) { photo in
            guard let photo else { return }
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self) {
                    let ext = photo.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    store.attach(data: data, name: "photo-" + UUID().uuidString + "." + ext)
                }
                pickedPhoto = nil
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls.prefix(4 - store.draftAttachments.count) {
                store.attach(fileURL: url)
            }
        }
        .onDisappear {
            dictation.stop()
            composerFocused = false
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-neo-chat-rich-fixture") { return }
            #endif
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

            if !store.draftAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.draftAttachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text(attachment.name).lineLimit(1)
                                Button {
                                    store.removeAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .accessibilityLabel("Remove " + attachment.name)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Menu {
                    PhotosPicker(selection: $pickedPhoto, matching: .images) {
                        Label("Photo", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        importingFile = true
                    } label: {
                        Label("File", systemImage: "doc")
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

                Button { showClearHistoryConfirmation = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Clear chat history")
                .accessibilityIdentifier("neoChatClearHistory")

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
                    if store.send(using: master) {
                        composerFocused = false
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 34, height: 34)
                        .background(Color(uiColor: .label), in: Circle())
                }
                .disabled((store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                           store.draftAttachments.isEmpty) || store.draft.count > 2000)
                .opacity((store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          store.draftAttachments.isEmpty) ? 0.35 : 1)
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
                ChatMessageRichContent(text: item.text) { hash in
                    selectedMarkcut = ChatMarkcutReference(hash: hash)
                }
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
