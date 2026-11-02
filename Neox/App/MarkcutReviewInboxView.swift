import SwiftUI
import UIKit

/// Phone-side view of durable Markcut Review Sessions. Reads and decisions
/// always pass through Neo Master's saved authenticated MCP endpoint.
struct MarkcutReviewInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var remote = RemoteMCPClient()
    @State private var sessions: [[String: Any]] = []
    @State private var selectedGroup: MarkcutReviewGroup?
    @State private var selectedSessionID: String?
    @State private var html: String?
    @State private var previewOrigin: URL?
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
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("markcutReviewInboxClose")
                    Spacer(minLength: 4)
                    Text("Review Inbox").font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { Task { await sync() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .disabled(syncing)
                    .accessibilityLabel("Refresh reviews")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .background(Color(uiColor: .systemBackground))
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
                GeometryReader { proxy in
                    if let item = selectedItem(in: group) {
                        ZStack(alignment: .topTrailing) {
                            preview(for: item)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                            if let decision = item["decision"] as? [String: Any] {
                                Label((decision["decision"] as? String) == "approved" ? "Approved" : "Changes requested",
                                      systemImage: (decision["decision"] as? String) == "approved" ? "checkmark.seal.fill" : "arrow.uturn.backward.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .padding(7)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(10)
                                    .accessibilityIdentifier("markcutReviewDecision")
                            } else if item["status"] as? String == "superseded" {
                                Label("Historical revision · review disabled", systemImage: "clock.arrow.circlepath")
                                    .font(.caption.weight(.medium))
                                    .padding(7)
                                    .background(.regularMaterial, in: Capsule())
                                    .padding(10)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        ContentUnavailableView("No revisions", systemImage: "film")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    Button { selectedGroup = nil } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("markcutReviewPreviewClose")
                    Spacer(minLength: 2)
                    Menu {
                        ForEach(group.sessions, id: \.reviewSessionID) { revision in
                            Button {
                                guard revision.reviewSessionID != selectedSessionID else { return }
                                selectedSessionID = revision.reviewSessionID
                                html = nil
                                previewError = nil
                                feedback = ""
                                Task { await loadPreview(revision.value) }
                            } label: {
                                if revision.reviewSessionID == selectedSessionID {
                                    Label("\(revision.title) · \(MarkcutReviewGrouping.statusText(revision.value))", systemImage: "checkmark")
                                } else {
                                    Text("\(revision.title) · \(MarkcutReviewGrouping.statusText(revision.value))")
                                }
                            }
                            .accessibilityIdentifier("markcutReviewRevision-\(revision.reviewSessionID)")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(group.title).lineLimit(1)
                            if group.sessions.count > 1 {
                                let selectedIndex = group.sessions.firstIndex(where: { $0.reviewSessionID == selectedSessionID }) ?? 0
                                Text("\(selectedIndex + 1)/\(group.sessions.count)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Choose video or revision")
                    .accessibilityIdentifier("markcutReviewVersionMenu")
                    .frame(maxWidth: .infinity)
                    Spacer().frame(width: 44)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func preview(for item: [String: Any]) -> some View {
        // The sheet closure can outlive the parent View's captured @State values.
        // Let a dedicated Binding-backed child observe the asynchronous preview.
        MarkcutReviewSurface(html: $html, origin: $previewOrigin,
            error: $previewError, loadingStage: $loadingStage, retry: $previewRetry) {
            Task { await loadPreview(item) }
        }
    }

    private func decisionControls(for item: [String: Any]) -> some View {
        VStack(spacing: 7) {
            TextField("Add feedback for changes…", text: $feedback, axis: .vertical)
                .lineLimit(3...8)
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-markcut-review-async-preview-fixture") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                html = "<html><body><div>Async preview ready</div></body></html>"
                previewRetry += 1
            }
            return
        }
        #endif
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
            let data = try JSONSerialization.data(withJSONObject: compiled, options: [.fragmentsAllowed])
            let encoded = data.base64EncodedString()
            previewOrigin = URL(string: player).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }.flatMap {
                var root = $0; root.path = "/"; root.query = nil; root.fragment = nil; return root.url
            }
            let aspect = width / max(1, height)
            // The player bundle consumes the injected revision on first render.
            // Decode UTF-8 explicitly so non-ASCII scene metadata stays valid.
            html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
            <style>
            html,body,#remotion-root{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:transparent;color:white}
            #remotion-preview{position:absolute;inset:0;width:100%;height:100%;box-sizing:border-box;display:flex;flex-direction:column;justify-content:center;align-items:center;gap:8px;overflow:hidden;background:transparent}
            #remotion-canvas{flex:0 0 auto;width:100%!important;max-width:100%!important;max-height:none!important;aspect-ratio:\(Int(width))/\(Int(height));margin:0!important;background:#111;border-radius:12px;overflow:hidden}
            #scene-thumbnails{box-sizing:border-box;flex:0 0 42px;height:42px;width:100%;min-width:0;display:flex;flex-wrap:nowrap;gap:8px;align-items:center;justify-content:flex-start;overflow-x:auto;overflow-y:hidden;white-space:nowrap;padding:4px 8px;scrollbar-width:none;-webkit-overflow-scrolling:touch;touch-action:pan-x;overscroll-behavior-x:contain}
            #scene-thumbnails::-webkit-scrollbar{display:none}
            #scene-thumbnails .scene-pill{box-sizing:border-box;flex:0 0 auto;white-space:nowrap;font-size:12px;line-height:22px;border-radius:8px;background:#282b32;color:#ddd;padding:3px 11px;cursor:pointer}
            #scene-thumbnails .scene-pill.active{background:#245da0;color:#fff}
            .comment-marker{display:none!important}
            .markcut-scene-nav{position:fixed;z-index:15;display:none;width:28px;height:42px;border:none;border-radius:8px;background:#191b20;color:#fff;font-size:23px;cursor:pointer;opacity:0.95;padding:0}
            </style>
            <div id="remotion-root"></div>
            <script>
            window.__markcutRevision={compiled:JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0))))};
            // The WebView is smaller than the phone screen and changes with the
            // feedback keyboard. Measure its real viewport rather than UIScreen.
            // Reserve a full scene-list row before fitting the video frame.
            (function(){
              const ratio=\(aspect);
              const container=document.getElementById('remotion-root');
              function sceneButton(id, symbol, direction){
                const button=document.createElement('button');
                button.id=id;button.className='markcut-scene-nav';button.textContent=symbol;
                button.setAttribute('aria-label',direction<0?'Previous scenes':'Next scenes');
                button.addEventListener('click',()=>{
                  document.getElementById('scene-thumbnails')?.scrollBy({left:direction*260,behavior:'smooth'});
                });
                document.body.appendChild(button);return button;
              }
              const prev=sceneButton('markcut-scene-prev','‹',-1);
              const next=sceneButton('markcut-scene-next','›',1);
              let observedStrip=null;
              function updateSceneNav(){
                const strip=document.getElementById('scene-thumbnails');
                if(!strip){prev.style.display='none';next.style.display='none';return;}
                if(observedStrip!==strip){
                  observedStrip=strip;
                  strip.addEventListener('scroll',updateSceneNav,{passive:true});
                }
                const rect=strip.getBoundingClientRect();
                const overflowing=strip.scrollWidth>strip.clientWidth+3 && rect.height>0;
                const maxScroll=strip.scrollWidth-strip.clientWidth;
                for(const button of [prev,next]){
                  button.style.top=rect.top+'px';
                  button.style.height=rect.height+'px';
                }
                prev.style.left=rect.left+'px';
                next.style.left=(rect.right-28)+'px';
                prev.style.display=overflowing&&strip.scrollLeft>3?'block':'none';
                next.style.display=overflowing&&strip.scrollLeft<maxScroll-3?'block':'none';
              }
              function fit(){
                const panel=document.getElementById('remotion-preview');
                const canvas=document.getElementById('remotion-canvas');
                if(!panel||!canvas)return;
                const availableWidth=Math.max(1,panel.clientWidth);
                const availableHeight=Math.max(1,panel.clientHeight-50);
                const fittedWidth=Math.max(1,Math.floor(Math.min(availableWidth,availableHeight*ratio)));
                canvas.style.setProperty('width',fittedWidth+'px','important');
                updateSceneNav();
              }
              new ResizeObserver(fit).observe(container);
              new MutationObserver(fit).observe(container,{childList:true,subtree:false});
              window.addEventListener('resize',fit);
              requestAnimationFrame(fit);
              setInterval(updateSceneNav,700);
            })();

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

/// Binding-backed preview renderer. A sheet's content closure may be created
/// before the remote MCP media arrives; this view must observe the new HTML.
private struct MarkcutReviewSurface: View {
    @Binding var html: String?
    @Binding var origin: URL?
    @Binding var error: String?
    @Binding var loadingStage: String
    @Binding var retry: Int
    let onRetry: () -> Void

    var body: some View {
        Group {
            if let html {
                MarkcutWebPreview(html: html, baseURL: origin, failure: $error, retry: retry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.1)))
                    .accessibilityIdentifier("markcutReviewPlayer")
                    .overlay(alignment: .topLeading) {
                        if let error {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                Button("Retry preview", action: onRetry)
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("markcutReviewRetry")
                            }
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
            } else if let error {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("markcutReviewRetry")
            } else {
                ProgressView(loadingStage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}
