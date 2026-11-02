import SwiftUI
import WebKit
import UIKit

/// Phone-side view of the same durable Markcut Review Sessions used by the
/// hosted Markcut app. All reads and decisions pass through Neo Master's saved
/// authenticated MCP endpoint.
struct MarkcutReviewInboxView: View {
    @StateObject private var remote = RemoteMCPClient()
    @State private var sessions: [[String: Any]] = []
    @State private var selected: [String: Any]?
    @State private var html: String?
    @State private var previewOrigin: URL?
    @State private var feedback = ""
    @State private var message: String?
    @State private var syncing = false
    @State private var queued = MarkcutReviewDecision.loadQueue(from: .standard)

    var body: some View {
        NavigationStack {
            List {
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(sessions.enumerated()), id: \.offset) { entry in
                    let item = entry.element
                    Button { open(item) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((item["title"] as? String) ?? (item["label"] as? String) ?? "Markcut review")
                                .font(.headline).lineLimit(1)
                            Text(statusText(item)).font(.caption).foregroundStyle(.secondary)
                            if let relay = (item["relayCorrelations"] as? [[String: Any]])?.first,
                               let task = relay["taskId"] { Text("Relay task · \(String(describing: task))").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityIdentifier("markcutReviewSession")
                }
            }
            .overlay {
                if sessions.isEmpty && !syncing { ContentUnavailableView("No video reviews", systemImage: "film", description: Text("Markcut previews from Neo Master will appear here.")) }
            }
            .navigationTitle("Review Inbox")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await sync() } } label: { Image(systemName: "arrow.clockwise") }.disabled(syncing) } }
            .task {
                while !Task.isCancelled {
                    await sync()
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                }
            }
            .sheet(item: Binding(get: { selected.map(ReviewSelection.init) }, set: { selected = $0?.value })) { selection in
                reviewSheet(selection.value)
            }
        }
    }

    private func reviewSheet(_ item: [String: Any]) -> some View {
        NavigationStack {
            VStack(spacing: 10) {
                if let html { MarkcutWebPreview(html: html, baseURL: previewOrigin).frame(minHeight: 280) }
                else { ProgressView("Loading compiled preview…").frame(maxWidth: .infinity, minHeight: 280) }
                if let decision = item["decision"] as? [String: Any] {
                    Label((decision["decision"] as? String) == "approved" ? "Approved" : "Changes requested", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).accessibilityIdentifier("markcutReviewDecision")
                } else if item["status"] as? String == "superseded" {
                    Label("Historical revision · review disabled", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
                } else {
                    TextEditor(text: $feedback).frame(height: 78).overlay(alignment: .topLeading) {
                        if feedback.isEmpty { Text("Feedback (required to request changes)").font(.caption).foregroundStyle(.secondary).padding(8).allowsHitTesting(false) }
                    }
                    HStack {
                        Button("Request changes") { Task { await submit("changes_requested", item: item) } }
                            .buttonStyle(.bordered).disabled(syncing || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Approve") { Task { await submit("approved", item: item) } }
                            .buttonStyle(.borderedProminent).disabled(syncing)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Markcut Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { selected = nil; html = nil } } }
            .task(id: item["contentHash"] as? String) { await loadPreview(item) }
        }
    }

    private func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            if !remote.connected { await remote.connect() }
            guard remote.connected else { throw NSError(domain: "MarkcutReviewInbox", code: 1, userInfo: [NSLocalizedDescriptionKey:"Neo Master is not connected"]) }
            // Replay a persisted decision with its original idempotency key.
            for (key, value) in Array(queued) {
                do {
                    _ = try await remote.decideMarkcutReview(sessionID: value.sessionID,
                        contentHash: value.contentHash, decision: value.choice.rawValue,
                        comments: value.comments.map { ["scope":$0.scope,"text":$0.text] }, idempotencyKey: key)
                    queued.removeValue(forKey: key)
                } catch {
                    message = "A queued review could not sync yet: \(error.localizedDescription)"
                    if error.localizedDescription.contains("current compiled revision") || error.localizedDescription.contains("decision already exists") {
                        queued.removeValue(forKey: key)
                    }
                }
            }
            MarkcutReviewDecision.saveQueue(queued, to: .standard)
            sessions = try await remote.listMarkcutReviewSessions()
            message = queued.isEmpty ? "Synced with Neo Master" : "Offline decision queued · waiting for Neo Master"
        } catch { message = "Offline · saved reviews will resync when Neo Master is reachable" }
    }

    private func open(_ item: [String: Any]) {
        // Clear the previous revision before presenting the next sheet. Its
        // .task(id:) owns media loading; a second load here would race it.
        html = nil
        previewOrigin = nil
        feedback = ""
        selected = item
    }

    private func loadPreview(_ item: [String: Any]) async {
        guard let sessionID = item["id"] as? String, let hash = item["contentHash"] as? String,
              ["ready", "decided", "superseded"].contains(item["status"] as? String ?? "") else { return }
        do {
            if !remote.connected { await remote.connect() }
            let media = try await remote.markcutReviewMedia(sessionID: sessionID, contentHash: hash)
            // The user may have closed this sheet or selected another review
            // while the MCP request was in flight. Never publish stale media.
            guard !Task.isCancelled,
                  selected?["id"] as? String == sessionID,
                  selected?["contentHash"] as? String == hash else { return }
            guard let compiled = media["compiled"], let player = media["playerUrl"] as? String else {
                throw NSError(domain: "MarkcutReviewInbox", code: 2, userInfo: [NSLocalizedDescriptionKey:"Neo Master returned no compiled preview"])
            }
            let data = try JSONSerialization.data(withJSONObject: compiled, options: [.fragmentsAllowed])
            let encoded = data.base64EncodedString()
            previewOrigin = URL(string: player).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }.flatMap {
                var root = $0; root.path = "/"; root.query = nil; root.fragment = nil; return root.url
            }
            html = "<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body,#remotion-root{margin:0;min-height:100%;background:#111;color:white}body{overflow:auto}</style><div id='remotion-root'></div><script>window.__markcutRevision={compiled:JSON.parse(atob('\(encoded)'))};</script><script src='\(player)'></script>"
        } catch is CancellationError {
            // Dismissal or revision replacement cancels the sheet task.
        } catch let error as URLError where error.code == .cancelled {
            // URLSession may surface the same sheet cancellation as -999.
        } catch {
            guard !Task.isCancelled, selected?["id"] as? String == sessionID,
                  selected?["contentHash"] as? String == hash else { return }
            message = "Preview unavailable: \(error.localizedDescription)"
        }
    }

    private func submit(_ decision: String, item: [String: Any]) async {
        guard !syncing else { return }
        guard let sessionID = item["id"] as? String, let hash = item["contentHash"] as? String else { return }
        if queued.values.contains(where: { $0.sessionID == sessionID && $0.contentHash == hash }) {
            message = "A decision for this revision is already queued for sync"
            return
        }
        let choice: MarkcutReviewChoice = decision == "approved" ? .approved : .changesRequested
        let comments = choice == .changesRequested ? [MarkcutReviewComment(scope:"overall",text:feedback.trimmingCharacters(in: .whitespacesAndNewlines))] : []
        guard let pending = try? MarkcutReviewDecision(sessionID:sessionID,contentHash:hash,choice:choice,comments:comments) else { return }
        let key = pending.idempotencyKey
        queued[key] = pending
        MarkcutReviewDecision.saveQueue(queued, to: .standard)
        syncing = true
        defer { syncing = false }
        do {
            if !remote.connected { await remote.connect() }
            _ = try await remote.decideMarkcutReview(sessionID:sessionID,contentHash:hash,decision:decision,comments:comments.map { ["scope":$0.scope,"text":$0.text] },idempotencyKey:key)
            queued.removeValue(forKey:key); MarkcutReviewDecision.saveQueue(queued, to:.standard)
            message = decision == "approved" ? "Approved for this revision" : "Changes requested for this revision"
            sessions = try await remote.listMarkcutReviewSessions()
            if let updated = sessions.first(where: { $0["id"] as? String == sessionID }) { selected = updated }
        } catch {
            message = "Decision saved on this phone; it will sync when Neo Master is reachable"
        }
    }

    private func statusText(_ item: [String: Any]) -> String {
        let status = item["status"] as? String ?? "pending"
        if let decision = item["decision"] as? [String: Any], let value = decision["decision"] as? String { return value == "approved" ? "Approved" : "Changes requested" }
        return status == "ready" ? "Ready for review" : status.capitalized
    }
}

private struct ReviewSelection: Identifiable { let value: [String: Any]; var id: String { value["id"] as? String ?? UUID().uuidString }; init(_ value: [String: Any]) { self.value = value } }

private struct MarkcutWebPreview: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: baseURL)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML: String? }
}
