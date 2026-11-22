import Foundation
import CryptoKit
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
    @Published private(set) var lastFailedRequestID: String?
    @Published var draft = ""
    @Published var draftAttachments: [ChatLocalAttachment] = []
    @Published private(set) var clearedAt: Date?

    private let preferences: UserDefaults
    private static let historyClearKey = "neo.chat.history.hidden-before.v1"
    private let outbox: ChatGatewayOutbox
    private let history: ChatGatewayHistory
    private var refreshing = false
    private var flushing = false
    private var unifiedAvailable = false

    init(outbox: ChatGatewayOutbox = ChatGatewayOutbox(), preferences: UserDefaults = .standard,
         history: ChatGatewayHistory? = nil) {
        self.outbox = outbox
        self.history = history ?? ChatGatewayHistory()
        self.preferences = preferences
        items = self.history.items
        clearedAt = preferences.object(forKey: Self.historyClearKey) as? Date
        queued = outbox.messages
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-neo-chat-rich-fixture") {
            let hash = String(repeating: "a", count: 64)
            let sample = """
            **Summary**: Orchestrator replies using `reply.text` and `reply.completed`.

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
        // A successful unified probe freezes the legacy sender for this view.
        guard !unifiedAvailable, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        // The Chat screen is deliberately presentation-only. Connection,
        // credential discovery, account preparation, provisioning and retries
        // are owned by the phone client and Mac service, not UI instructions.
        guard master.hasConfiguredAddress && master.hasCredential else { return }
        if !master.connected { await master.connect() }
        guard master.connected else { return }

        do {
            let legacy = try await master.chatGatewayFeed()
            try history.importLegacyOnce(legacy)
            items = history.items
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

    /// Old MCP is deliberately retired before REST cutover. Preserve locally
    /// saved history/outbox even when one-time server history import is not
    /// available; never mark import completed unless it really succeeded.
    func importLegacyIfAvailable(_ readLegacy: () async throws -> [ChatGatewayItem]) async {
        guard !history.hasImportedLegacy else { return }
        do {
            try history.importLegacyOnce(await readLegacy())
            items = history.items
        } catch {
            // The old provider may already be unregistered. A failed import
            // must not block REST/SSE or discard phone-owned local messages.
        }
    }

    /// One SSE listener per visible Chat tab. REST/SSE is authoritative once
    /// authenticated. If unavailable, keep the local outbox for later retry.
    func runUnifiedSession(using master: RemoteMCPClient) async -> Bool {
        guard master.hasConfiguredAddress && master.hasCredential else { return false }
        // The unified REST/SSE route is independent of MCP connectivity.
        // An unavailable or removed legacy MCP provider must not strand Chat.
        do {
            let rest = try master.unifiedGatewayREST()
            if master.connected {
                await importLegacyIfAvailable { try await master.chatGatewayFeed() }
            }
            let receipt = try await rest.json("GET", path: "/orchestrator-chat/pending")
            guard let pending = receipt["pending"] as? [[String: Any]] else {
                throw GatewayRESTError.invalidResponse
            }
            unifiedAvailable = true
            try await reconcileUnifiedPending(pending, rest: rest)
            try await flushUnified(using: rest)
            let key = unifiedCursorKey(for: master.endpoint)
            let cursor = max(0, preferences.integer(forKey: key))
            // Recover un-ACKed complete replies even if an already-open SSE
            // stream stops delivering bytes through iOS/Cloudflare. This task
            // runs only while the Chat tab is visible and cannot send twice:
            // persisted replies are keyed by requestId, and ACK is idempotent.
            let pendingRecovery = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(4)) }
                    catch { return }
                    guard let self else { return }
                    do {
                        let fresh = try await rest.json("GET", path: "/orchestrator-chat/pending")
                        guard let waiting = fresh["pending"] as? [[String: Any]] else { continue }
                        try await self.reconcileUnifiedPending(waiting, rest: rest)
                    } catch {
                        // Keep the SSE listener alive. Temporary network errors
                        // are retried by the next four-second reconciliation.
                    }
                }
            }
            defer { pendingRecovery.cancel() }
            do {
                try await rest.events(after: cursor) { [weak self] payload in
                guard let self else { return }
                let value = try JSONSerialization.jsonObject(with: payload)
                guard let event = value as? [String: Any],
                      let id = event["id"] as? Int, id > 0,
                      let requestID = event["requestId"] as? String,
                      let status = event["status"] as? String else {
                    throw GatewayRESTError.invalidResponse
                }
                let previous = self.preferences.integer(forKey: key)
                guard id > previous else { return } // Replay is idempotent.
                guard id == previous + 1 else { throw GatewayRESTError.invalidResponse }
                let reply: [String: Any]? = {
                    guard let text = event["text"] as? String else { return nil }
                    return ["text": text, "level": event["level"] as? String ?? "info",
                            "jobId": event["jobId"] as? String ?? ""]
                }()
                try self.history.update(requestID: requestID, status: status, message: reply)
                self.items = self.history.items
                if status == "failed" { self.lastFailedRequestID = requestID }
                if ["completed", "failed"].contains(status) {
                    guard let deliveryID = event["deliveryId"] as? String else {
                        throw GatewayRESTError.invalidResponse
                    }
                    _ = try await rest.json("POST", path: "/orchestrator-chat/ack", body: ["deliveryId": deliveryID])
                }
                // Advance only after the relevant text and ACK are durable.
                self.preferences.set(id, forKey: key)
                }
            } catch GatewayRESTError.http(409) {
                // Cursor expired. Re-fetch and DURABLY reconcile the latest
                // unacknowledged terminal replies before advancing the cursor.
                // The earlier pending snapshot may have become stale.
                let fresh = try await rest.json("GET", path: "/orchestrator-chat/pending")
                guard let pending = fresh["pending"] as? [[String: Any]],
                      let baseline = fresh["cursor"] as? Int, baseline >= cursor else {
                    throw GatewayRESTError.invalidResponse
                }
                try await reconcileUnifiedPending(pending, rest: rest)
                preferences.set(baseline, forKey: key)
            }
            return true
        } catch {
            // After a successful REST probe never route the same outbox to
            // legacy: that could submit a request into a different thread.
            return unifiedAvailable
        }
    }

    private func unifiedCursorKey(for endpoint: String) -> String {
        let bytes = SHA256.hash(data: Data(endpoint.utf8))
        return "neo.orchestrator.cursor." + bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func reconcileUnifiedPending(_ pending: [[String: Any]], rest: UnifiedGatewayREST) async throws {
        for item in pending {
            guard let id = item["requestId"] as? String,
                  let status = item["status"] as? String else {
                throw GatewayRESTError.invalidResponse
            }
            try history.update(requestID: id, status: status,
                               message: item["message"] as? [String: Any])
            if status == "failed" { lastFailedRequestID = id }
            if ["completed", "failed"].contains(status) {
                guard let deliveryID = item["deliveryId"] as? String else {
                    throw GatewayRESTError.invalidResponse
                }
                _ = try await rest.json("POST", path: "/orchestrator-chat/ack", body: ["deliveryId": deliveryID])
            }
        }
        items = history.items
    }

    private func flushUnified(using rest: UnifiedGatewayREST) async throws {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        for message in outbox.messages {
            let attachments = message.attachments ?? []
            guard attachments.count <= 4 else { throw GatewayRESTError.invalidResponse }
            let refs = attachments.map { ["id": $0.id, "name": $0.name] }
            let messageBody: [String: Any] = [
                "requestId": message.id,
                "text": message.text.isEmpty ? "See attached files." : message.text,
                "attachments": refs
            ]
            if !attachments.isEmpty {
                // A lost 202 may leave this message in the local outbox even
                // though Models already accepted (and perhaps ACKed) it.
                // Revalidate the exact request body before touching its files:
                // the server refuses new uploads after acceptance.
                let known = try await rest.json("GET", path: "/orchestrator-chat/pending",
                    query: [URLQueryItem(name: "requestId", value: message.id)])
                guard let accepted = known["accepted"] as? Bool else {
                    throw GatewayRESTError.invalidResponse
                }
                if accepted {
                    let replay = try await rest.json("POST", path: "/orchestrator-chat/messages",
                                                     body: messageBody, expectedStatus: 202)
                    guard replay["requestId"] as? String == message.id else {
                        throw GatewayRESTError.invalidResponse
                    }
                    try history.markSubmitted(message.id)
                    try outbox.acknowledge(message.id)
                    items = history.items
                    queued = outbox.messages
                    continue
                }
            }
            // Upload SHA-256 checked chunks before accepting a new message.
            // Every chunk is repeatable under the same request/attachment ID.
            for attachment in attachments {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: attachment.path))
                guard !bytes.isEmpty, bytes.count == attachment.size, bytes.count <= 12 * 1024 * 1024,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == attachment.sha256 else {
                    throw GatewayRESTError.invalidResponse
                }
                let chunkSize = 128 * 1024
                let count = (bytes.count + chunkSize - 1) / chunkSize
                guard count > 0 && count <= 96 else { throw GatewayRESTError.invalidResponse }
                for index in 0..<count {
                    let from = index * chunkSize
                    let chunk = bytes.subdata(in: from..<min(bytes.count, from + chunkSize))
                    let reply = try await rest.json("POST", path: "/orchestrator-chat/attachments",
                        body: ["requestId": message.id, "attachmentId": attachment.id,
                               "name": attachment.name, "chunkIndex": index, "chunkCount": count,
                               "contentBase64": chunk.base64EncodedString(),
                               "sha256": attachment.sha256, "size": attachment.size])
                    // Already-complete files may return complete=true for
                    // *every* replayed chunk after an uncertain network result.
                    guard reply["attachmentId"] as? String == attachment.id,
                          let complete = reply["complete"] as? Bool,
                          (index < count - 1 || complete) else {
                        throw GatewayRESTError.invalidResponse
                    }
                }
            }
            let receipt = try await rest.json("POST", path: "/orchestrator-chat/messages",
                                              body: messageBody, expectedStatus: 202)
            guard receipt["requestId"] as? String == message.id else {
                throw GatewayRESTError.invalidResponse
            }
            try history.markSubmitted(message.id)
            try outbox.acknowledge(message.id)
            items = history.items
            queued = outbox.messages
        }
    }

    func send(using master: RemoteMCPClient) -> Bool {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!message.isEmpty || !draftAttachments.isEmpty), message.count <= 2000 else { return false }

        // Commit locally BEFORE clearing the composer. A disconnected phone
        // or temporarily unavailable head never requires a Retry tap.
        do {
            try outbox.enqueue(message, attachments: draftAttachments)
            // Local transcript and delivery queue have independent durable owners.
            // If history persistence fails, the queued request is still recoverable.
            if let pending = outbox.messages.last { try? history.owner(pending) }
            items = history.items
            queued = outbox.messages
            draft = ""
            draftAttachments = []
        } catch {
            // If local persistence fails, keep the draft intact, not a fake sent state.
            return false
        }
        // Start delivery immediately, but do not keep the composer focused
        // while a gateway request is in flight.
        Task {
            if unifiedAvailable {
                if let rest = try? master.unifiedGatewayREST() {
                    try? await flushUnified(using: rest)
                }
            } else {
                await refresh(from: master)
            }
        }
        return true
    }

    /// Voice uses the SAME durable outbox, request ID, Chat REST/SSE and
    /// timeline as typed messages. It must never overwrite a typed draft.
    func sendVoiceText(_ spoken: String, using master: RemoteMCPClient) -> String? {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else { return nil }
        do {
            let message = try outbox.enqueue(text)
            try? history.owner(message)
            items = history.items
            queued = outbox.messages
            Task {
                if unifiedAvailable {
                    if let rest = try? master.unifiedGatewayREST() {
                        try? await flushUnified(using: rest)
                    }
                } else {
                    await refresh(from: master)
                }
            }
            return message.id
        } catch { return nil }
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
                try history.markSubmitted(message.id)
                try outbox.acknowledge(message.id)
                items = history.items
                queued = outbox.messages
            } catch {
                // Preserve durable pending work and stable request ID; next
                // foreground/poll/reconnect retries without user intervention.
                return
            }
        }
        if !queued.isEmpty { return }
        if let latest = try? await master.chatGatewayFeed() {
            try? history.importLegacyOnce(latest)
            items = history.items
        }
    }
}

struct ChatGatewayView: View {
    @ObservedObject var master: RemoteMCPClient
    let isActive: Bool
    @StateObject private var store = ChatGatewayStore()
    @StateObject private var dictation = ChatComposerDictation()
    @StateObject private var voice = ChatVoiceConversation()
    @State private var voiceDraftPreview = ChatVoiceDraftPreview()
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
        .onChange(of: voice.transcript) { _, text in
            guard voiceIsRunning,
                  let preview = voiceDraftPreview.render(transcript: text,
                                                         currentDraft: store.draft) else { return }
            store.draft = preview
        }
        .onChange(of: voice.committedTurn) { _, turn in
            guard let turn else { return }
            // The interim STT suffix was shown in the composer; only the
            // speech itself is sent. Restore any unsent typed draft.
            store.draft = voiceDraftPreview.committed(currentDraft: store.draft)
            if let requestID = store.sendVoiceText(turn.text, using: master) {
                voice.expectReply(requestID: requestID)
            } else {
                stopVoice()
            }
        }
        .onChange(of: voice.phase) { _, phase in
            if phase == .error { voiceDraftPreview.cancel() }
        }
        .onChange(of: store.lastFailedRequestID) { _, requestID in
            if let requestID { voice.receiveFailure(requestID: requestID) }
        }
        .onChange(of: store.items) { _, records in
            for item in records where item.kind == "report" {
                voice.receive(item)
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
                stopVoice()
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
            stopVoice()
            composerFocused = false
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-neo-chat-rich-fixture") { return }
            #endif
            // Prefer durable REST/SSE when verified, otherwise retain the
            // existing working legacy feed until full cutover.
            while !Task.isCancelled {
                let unified = await store.runUnifiedSession(using: master)
                if !unified { await store.refresh(from: master) }
                do { try await Task.sleep(for: .seconds(unified ? 2 : 8)) }
                catch { return }
            }
        }
    }

    private var voiceIsRunning: Bool {
        switch voice.phase {
        case .starting, .listening, .thinking, .speaking: true
        case .idle, .stopped, .error: false
        }
    }

    private var voiceIconName: String {
        switch voice.phase {
        case .starting: "waveform.circle"
        case .listening: "waveform.circle.fill"
        case .thinking: "ellipsis.circle.fill"
        case .speaking: "speaker.wave.2.fill"
        case .error: "exclamationmark.circle"
        case .idle, .stopped: "waveform.circle"
        }
    }

    private var voiceIconColor: Color {
        switch voice.phase {
        case .listening: .red
        case .thinking: .orange
        case .speaking: .blue
        case .error: .red
        case .starting: .orange
        case .idle, .stopped: .primary
        }
    }

    private func stopVoice() {
        voice.stop()
        // Keep the in-progress recognized text available for editing if the
        // user stopped speaking before the automatic utterance commit.
        voiceDraftPreview.cancel()
    }

    private func toggleVoice() {
        if voiceIsRunning {
            stopVoice()
        } else {
            dictation.stop() // LiveKit and one-shot dictation cannot own the mic together.
            composerFocused = false
            voiceDraftPreview.begin(draft: store.draft)
            Task { await voice.start() }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(voiceIsRunning ? (voice.phase == .thinking ? "Waiting for reply…" : "Listening…") : "Message",
                      text: $store.draft, axis: .vertical)
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
            HStack(spacing: 8) {
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
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 30)
                        .background(Color(.tertiarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("neoChatAdd")

                Button { showClearHistoryConfirmation = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Clear chat history")
                .accessibilityIdentifier("neoChatClearHistory")

                Spacer(minLength: 0)

                Button(action: toggleVoice) {
                    Image(systemName: voiceIconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(voiceIconColor)
                        .frame(width: 30, height: 30)
                        .background(voiceIsRunning ? voiceIconColor.opacity(0.12) : .clear,
                                    in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel(voiceIsRunning ? "Stop voice conversation" : "Voice conversation")
                .accessibilityValue(voice.phase.rawValue.capitalized)
                .accessibilityHint(voice.errorText ?? "Tap to start or stop live voice")
                .accessibilityIdentifier("neoChatVoiceConversation")

                Button {
                    if voiceIsRunning { stopVoice() }
                    if !dictation.isRecording && !dictation.isStarting {
                        dictationPrefix = store.draft
                        composerFocused = false
                    }
                    dictation.toggle()
                } label: {
                    Image(systemName: dictation.isRecording ? "stop.fill" : "mic")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.primary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                .accessibilityIdentifier("neoChatMicrophone")

                Button {
                    dictation.stop()
                    if voiceIsRunning { stopVoice() }
                    if store.send(using: master) {
                        composerFocused = false
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 30, height: 30)
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
