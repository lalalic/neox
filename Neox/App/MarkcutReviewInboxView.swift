import SwiftUI
import UIKit

/// Phone-side view of durable Markcut Review Sessions. Reads and decisions
/// always pass through Neo Master's saved authenticated MCP endpoint.
struct MarkcutReviewInboxView: View {
    @StateObject private var remote = RemoteMCPClient()
    @State private var sessions: [[String: Any]] = []
    @State private var selectedGroup: MarkcutReviewGroup?
    @State private var selectedSessionID: String?
    @State private var html: String?
    @State private var previewOrigin: URL?
    @State private var previewDimensions = CGSize(width: 1080, height: 1920)
    @State private var previewError: String?
    @State private var loadingStage = "Loading preview…"
    @State private var previewRetry = 0
    @State private var feedback = ""
    @State private var message: String?
    @State private var syncing = false
    @State private var queued = MarkcutReviewDecision.loadQueue(from: .standard)

    private var groups: [MarkcutReviewGroup] { MarkcutReviewGrouping.groups(from: sessions) }
    private func selectedItem(in group: MarkcutReviewGroup) -> [String: Any]? {
        return group.sessions.filter { $0.reviewSessionID == selectedSessionID }.first?.value
            ?? group.sessions.first?.value
    }

    var body: some View {
        NavigationStack {
            List {
                if let message, message != "Synced with Neo Master" {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    Button { open(group) } label: {
                        ReviewGroupRow(group: group)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("markcutReviewGroup")
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if sessions.isEmpty && !syncing {
                    ContentUnavailableView("No video reviews", systemImage: "film",
                        description: Text("Markcut previews from Neo Master will appear here."))
                }
            }
            .navigationTitle("Review Inbox")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await sync() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(syncing)
                        .accessibilityLabel("Refresh reviews")
                }
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-markcut-review-ui-fixture") {
                    sessions = MarkcutReviewGrouping.uiFixture
                    return
                }
                #endif
                while !Task.isCancelled {
                    await sync()
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                }
            }
            .sheet(item: $selectedGroup, onDismiss: clearSelection) { group in
                reviewSheet(group)
            }
        }
    }

    private func reviewSheet(_ group: MarkcutReviewGroup) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The clip picker is always visible while reviewing, even on a
                // long portrait film or when the keyboard is open.
                revisionPicker(group)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                Divider()
                ScrollView {
                    if let item = selectedItem(in: group) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(displayTitle(item))
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                statusBadge(item)
                            }
                            preview(for: item)
                            if let decision = item["decision"] as? [String: Any] {
                                Label((decision["decision"] as? String) == "approved" ? "Approved" : "Changes requested",
                                      systemImage: (decision["decision"] as? String) == "approved" ? "checkmark.seal.fill" : "arrow.uturn.backward.circle.fill")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle((decision["decision"] as? String) == "approved" ? .green : .orange)
                                    .accessibilityIdentifier("markcutReviewDecision")
                            } else if item["status"] as? String == "superseded" {
                                Label("Historical revision · review disabled", systemImage: "clock.arrow.circlepath")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    } else {
                        ContentUnavailableView("No revisions", systemImage: "film")
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                // Do not place action buttons after a potentially 40-second film
                // in the scroll view. The decision dock remains reachable.
                if let item = selectedItem(in: group), item["status"] as? String == "ready",
                   !(item["decision"] is [String: Any]) {
                    Divider()
                    decisionControls(for: item)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
                if let message, message != "Synced with Neo Master" {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).padding(.horizontal, 12).padding(.bottom, 6)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { selectedGroup = nil } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func revisionPicker(_ group: MarkcutReviewGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(group.sessions.count > 1 ? "VIDEOS & REVISIONS" : "CURRENT VIDEO")
                    .font(.caption2.weight(.semibold)).tracking(0.3).foregroundStyle(.secondary)
                Spacer()
                Text("\(group.sessions.count) \(group.sessions.count == 1 ? "version" : "versions")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(group.sessions.enumerated()), id: \.element.reviewSessionID) { index, item in
                        let isSelected = item.reviewSessionID == (selectedSessionID ?? group.sessions.first?.reviewSessionID)
                        Button {
                            guard !isSelected else { return }
                            selectedSessionID = item.reviewSessionID
                            html = nil
                            previewError = nil
                            feedback = ""
                            Task { await loadPreview(item.value) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.sessions.count > 1 ? "\(index + 1) · \(item.title)" : item.title)
                                    .font(.caption.weight(.semibold)).lineLimit(1)
                                Text(MarkcutReviewGrouping.statusText(item.value))
                                    .font(.caption2).lineLimit(1)
                                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(minWidth: group.sessions.count > 1 ? 146 : 185, alignment: .leading)
                            .background(isSelected ? Color.accentColor.opacity(0.10) : Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(isSelected ? "Selected" : "")
                        .accessibilityIdentifier("markcutReviewRevision-\(item.reviewSessionID)")
                    }
                }
            }
        }
    }

    @ViewBuilder private func preview(for item: [String: Any]) -> some View {
        if let html {
            MarkcutWebPreview(html: html, baseURL: previewOrigin, failure: $previewError, retry: previewRetry)
                .frame(height: previewHeight())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .accessibilityIdentifier("markcutReviewPlayer")
            if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button { Task { await loadPreview(item) } } label: {
                    Label("Retry preview", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("markcutReviewRetry")
            }
        } else if let previewError {
            ContentUnavailableView {
                Label("Preview unavailable", systemImage: "exclamationmark.triangle")
            } description: { Text(previewError) } actions: {
                Button("Retry") { Task { await loadPreview(item) } }.buttonStyle(.borderedProminent)
            }
            .frame(height: 210)
            .accessibilityIdentifier("markcutReviewRetry")
        } else {
            ProgressView(loadingStage)
                .frame(maxWidth: .infinity).frame(height: 210)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func previewCanvasSize() -> CGSize {
        let availableWidth = UIScreen.main.bounds.width - 24
        let aspect = previewDimensions.width / max(1, previewDimensions.height)
        let maxHeight = min(450, UIScreen.main.bounds.height * 0.52)
        let width = min(availableWidth, maxHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func previewHeight() -> CGFloat {
        // Reserve space for Markcut's scene strip beneath its Remotion canvas.
        min(505, max(170, previewCanvasSize().height + 42))
    }

    private func decisionControls(for item: [String: Any]) -> some View {
        VStack(spacing: 7) {
            TextField("Add feedback for changes…", text: $feedback, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("markcutReviewFeedback")
            HStack(spacing: 10) {
                Button { Task { await submit("changes_requested", item: item) } } label: {
                    Label("Request changes", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(syncing || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("markcutReviewRequestChanges")
                Button { Task { await submit("approved", item: item) } } label: {
                    Label("Approve", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(syncing)
                .accessibilityIdentifier("markcutReviewApprove")
            }
            .controlSize(.regular)
        }
    }

    private func statusBadge(_ item: [String: Any]) -> some View {
        let status = MarkcutReviewGrouping.statusText(item)
        return Text(status)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(status == "Ready for review" ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(status == "Ready for review" ? Color.orange : Color.secondary)
            .fixedSize()
    }

    private func displayTitle(_ item: [String: Any]) -> String {
        let label = (item["title"] as? String) ?? (item["label"] as? String) ?? "Video"
        if !["video", "video.md", "untitled"].contains(label.lowercased()) { return label }
        if let variant = item["videoItemTitle"] as? String { return variant.uppercased() }
        if let relay = (item["relayCorrelations"] as? [[String: Any]])?.first,
           let task = relay["taskId"] { return "Task \(task) · Video" }
        return "Video draft"
    }

    private func clearSelection() {
        selectedSessionID = nil
        html = nil
        previewOrigin = nil
        previewError = nil
        feedback = ""
    }

    private func open(_ group: MarkcutReviewGroup) {
        selectedGroup = group
        let first = group.sessions.first
        selectedSessionID = first?.reviewSessionID
        html = nil
        previewError = nil
        feedback = ""
        if let first { Task { await loadPreview(first.value) } }
    }

    private func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            if !remote.connected { await remote.connect() }
            guard remote.connected else { throw NSError(domain: "MarkcutReviewInbox", code: 1, userInfo: [NSLocalizedDescriptionKey:"Neo Master is not connected"]) }
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

    private func loadPreview(_ item: [String: Any]) async {
        guard let sessionID = item["id"] as? String, let hash = item["contentHash"] as? String,
              ["ready", "decided", "superseded"].contains(item["status"] as? String ?? "") else {
            previewError = "This revision has no compiled preview yet. Refresh after compilation finishes."
            return
        }
        previewError = nil
        loadingStage = "Connecting to Neo Master…"
        do {
            if !remote.connected { await remote.connect() }
            loadingStage = "Fetching compiled scenes…"
            let media = try await remote.markcutReviewMedia(sessionID: sessionID, contentHash: hash)
            // Remote responses can arrive after the user switches revisions or
            // dismisses the sheet. Never replace the selected preview with stale media.
            guard !Task.isCancelled, selectedSessionID == sessionID,
                  selectedGroup?.sessions.contains(where: { $0.reviewSessionID == sessionID }) == true else { return }
            loadingStage = "Preparing video player…"
            guard let compiled = media["compiled"], let player = media["playerUrl"] as? String else {
                throw NSError(domain: "MarkcutReviewInbox", code: 2, userInfo: [NSLocalizedDescriptionKey:"Neo Master returned no compiled preview"])
            }
            // The compiled scene tree gives actual aspect ratio (landscape/portrait).
            let tree = compiled as? [String: Any] ?? [:]
            let root = tree["root"] as? [String: Any] ?? tree
            let width = (root["width"] as? NSNumber)?.doubleValue ?? 1080
            let height = (root["height"] as? NSNumber)?.doubleValue ?? 1920
            previewDimensions = CGSize(width: max(1, width), height: max(1, height))
            let data = try JSONSerialization.data(withJSONObject: compiled, options: [.fragmentsAllowed])
            let encoded = data.base64EncodedString()
            previewOrigin = URL(string: player).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }.flatMap {
                var root = $0; root.path = "/"; root.query = nil; root.fragment = nil; return root.url
            }
            // The player bundle consumes the injected revision on first render.
            // Decode UTF-8 explicitly so non-ASCII scene metadata stays valid.
            html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
            <style>html,body,#remotion-root{margin:0;width:100%;min-height:0;background:#111;color:white}body{overflow:hidden}#remotion-preview{width:100%}#remotion-canvas{width:\(previewCanvasSize().width)px!important;max-height:none!important;margin:0 auto!important}#scene-thumbnails{display:flex;align-items:center;gap:6px;overflow-x:auto;white-space:nowrap;height:36px;padding:5px 10px;box-sizing:border-box;scrollbar-width:none}#scene-thumbnails .scene-pill{flex:0 0 auto;font-size:11px;line-height:19px;border-radius:7px;background:#282b32;color:#ddd;padding:0 9px}#scene-thumbnails .scene-pill.active{background:#245da0;color:#fff}</style>
            <div id="remotion-root"></div>
            <script>
            window.__markcutRevision={compiled:JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0))))};
            window.onerror=function(message){window.webkit.messageHandlers.markcutPreviewError.postMessage(String(message));};
            window.addEventListener('unhandledrejection',function(e){window.webkit.messageHandlers.markcutPreviewError.postMessage(String(e.reason||'Preview playback failed'));});
            window.addEventListener('error',function(e){if(e.target instanceof HTMLMediaElement)window.webkit.messageHandlers.markcutPreviewError.postMessage('Video or audio could not be loaded or decoded.');},true);
            </script><script src="\(player)"></script>
            """
            previewRetry += 1
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled, selectedSessionID == sessionID else { return }
            previewError = error.localizedDescription
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
            if let updated = sessions.first(where: { $0["id"] as? String == sessionID }) {
                selectedGroup = MarkcutReviewGrouping.groups(from: sessions).first(where: { group in
                    group.sessions.contains(where: { $0.reviewSessionID == sessionID })
                })
                selectedSessionID = updated["id"] as? String
            }
        } catch {
            message = "Decision saved on this phone; it will sync when Neo Master is reachable"
        }
    }
}

private struct ReviewGroupRow: View {
    let group: MarkcutReviewGroup
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.jobID == nil ? "film.stack" : "rectangle.stack.fill")
                .font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(group.title).font(.headline).lineLimit(1)
                HStack(spacing: 7) {
                    Text("\(group.sessions.count) \(group.sessions.count == 1 ? "revision" : "revisions")")
                    Text("·")
                    Text(group.pendingCount == 0 ? "No pending reviews" : "\(group.pendingCount) pending")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if group.pendingCount > 0 {
                Text("\(group.pendingCount)").font(.caption.weight(.bold))
                    .foregroundStyle(.white).frame(minWidth: 24, minHeight: 24)
                    .background(Color.orange, in: Circle())
                    .accessibilityHidden(true) // row's text already reports the pending count
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}
