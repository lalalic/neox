import Foundation
import SwiftUI
import WebKit

/// A chat report can contain ordinary Markdown, Mermaid charts, or a reference
/// to a compiled Markcut preview. Never execute untrusted Markdown as HTML.
enum ChatMessagePart: Equatable {
    case markdown(String)
    case mermaid(String)
    case markcut(String)
}

enum ChatMessageMarkup {
    private static let fences = try! NSRegularExpression(
        pattern: #"(?m)^```(mermaid|markcut)[ \t]*\r?\n([\s\S]*?)^```[ \t]*(?:\r?\n|$)"#,
        options: [.caseInsensitive]
    )
    private static let links = try! NSRegularExpression(
        pattern: #"(?i)\[[^\]\n]+\]\(markcut://preview/([a-f0-9]{64})\)|markcut://preview/([a-f0-9]{64})"#
    )
    private static let hashes = try! NSRegularExpression(
        pattern: #"(?i)\b(?:contentHash|mediaHash)\s*:\s*([a-f0-9]{64})\b"#
    )

    static func parse(_ source: String) -> [ChatMessagePart] {
        let ns = source as NSString
        let matches = fences.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var result: [ChatMessagePart] = []
        var cursor = 0
        for match in matches {
            if cursor < match.range.location {
                result.append(contentsOf: parseLinks(ns.substring(with: NSRange(
                    location: cursor, length: match.range.location - cursor))))
            }
            let language = ns.substring(with: match.range(at: 1)).lowercased()
            let body = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if language == "mermaid", !body.isEmpty, body.count <= 16_000 {
                result.append(.mermaid(body))
            } else if language == "markcut",
                      let found = hashes.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                result.append(.markcut((body as NSString).substring(with: found.range(at: 1)).lowercased()))
            } else {
                result.append(.markdown(ns.substring(with: match.range)))
            }
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length {
            result.append(contentsOf: parseLinks(ns.substring(from: cursor)))
        }
        return result.isEmpty ? [.markdown(source)] : result
    }

    private static func parseLinks(_ source: String) -> [ChatMessagePart] {
        let ns = source as NSString
        let found = links.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        var result: [ChatMessagePart] = []
        for match in found {
            if cursor < match.range.location {
                result.append(.markdown(ns.substring(with: NSRange(
                    location: cursor, length: match.range.location - cursor))))
            }
            let hashRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            result.append(.markcut(ns.substring(with: hashRange).lowercased()))
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { result.append(.markdown(ns.substring(from: cursor))) }
        return result
    }
}

struct ChatMessageRichContent: View {
    let text: String
    let onMarkcut: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMessageMarkup.parse(text).enumerated()), id: \.offset) { _, part in
                switch part {
                case .markdown(let source):
                    if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text((try? AttributedString(markdown: source)) ?? AttributedString(source))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .mermaid(let chart):
                    ChatMermaidDiagram(source: chart)
                        .accessibilityIdentifier("neoChatMermaid")
                case .markcut(let hash):
                    Button { onMarkcut(hash) } label: {
                        Label("Markcut video preview", systemImage: "play.rectangle.fill")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("neoChatMarkcutPreview")
                }
            }
        }
    }
}

private struct ChatMermaidDiagram: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 180

    var body: some View {
        MermaidWebView(source: source, dark: colorScheme == .dark, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Mermaid runs entirely from an MIT-licensed library packaged with Neo.
/// The WebView does not load private chart source from any remote service.
private struct MermaidWebView: UIViewRepresentable {
    let source: String
    let dark: Bool
    @Binding var height: CGFloat

    private static let renderer: String = {
        guard let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return script
    }()

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "mermaidHeight")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.renderer,
                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "neoChatMermaid"
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let identity = source + (dark ? "dark" : "light")
        guard context.coordinator.lastIdentity != identity else { return }
        context.coordinator.lastIdentity = identity
        let encoded = Data(source.utf8).base64EncodedString()
        let theme = dark ? "dark" : "default"
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'">
        <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
        #chart{width:100%;min-height:50px;overflow:hidden;display:flex;align-items:center;justify-content:center}
        #chart svg{display:block;max-width:100%!important;width:100%;height:auto}
        #error{white-space:pre-wrap;font:12px system-ui;color:#a33;padding:6px}</style>
        </head><body><div id="chart"></div><div id="error"></div>
        <script>
        (async function(){
          const resize=()=>window.webkit.messageHandlers.mermaidHeight.postMessage(
            Math.ceil(Math.max(80,Math.min(1200,document.body.scrollHeight+4))));
          try {
            if(typeof mermaid==='undefined') throw new Error('Mermaid renderer unavailable');
            const source=new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0)));
            mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'\(theme)',
              flowchart:{htmlLabels:false},maxTextSize:16000});
            const result=await mermaid.render('neo-mermaid-chart',source);
            document.getElementById('chart').innerHTML=result.svg;
            new ResizeObserver(resize).observe(document.getElementById('chart'));
            requestAnimationFrame(resize);
          } catch(e) {
            document.getElementById('error').textContent='Diagram unavailable: '+String(e.message||e);
            resize();
          }
        })();
        </script></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastIdentity: String?
        var height: Binding<CGFloat>
        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "mermaidHeight", let height = message.body as? NSNumber else { return }
            let pixels = CGFloat(height.doubleValue)
            guard pixels.isFinite else { return }
            DispatchQueue.main.async { self.height.wrappedValue = min(1200, max(80, pixels)) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme ?? ""
            decisionHandler(scheme == "about" ? .allow : .cancel)
        }
    }
}

struct ChatMarkcutReference: Identifiable {
    let hash: String
    var id: String { hash }
}

struct ChatMarkcutPreviewSheet: View {
    let master: RemoteMCPClient
    let hash: String
    @Environment(\.dismiss) private var dismiss
    @State private var html: String?
    @State private var origin: URL?
    @State private var error: String?
    @State private var playbackPosition: MarkcutPlaybackPosition?

    var body: some View {
        NavigationStack {
            Group {
                if let html {
                    MarkcutWebPreview(html: html, baseURL: origin, failure: $error,
                                      playbackPosition: $playbackPosition, retry: 0)
                } else if let error {
                    ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView("Loading Markcut preview…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Markcut preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task(id: hash) { await load() }
        }
    }

    private func load() async {
        do {
            let media = try await master.markcutPreviewMedia(contentHash: hash)
            guard let compiled = media["compiled"], let player = media["playerUrl"] as? String,
                  let playerURL = URL(string: player) else { throw ChatGatewayError.invalidItem }
            let json = try JSONSerialization.data(withJSONObject: compiled, options: [.fragmentsAllowed])
            let encoded = json.base64EncodedString()
            let tree = compiled as? [String: Any] ?? [:]
            let root = tree["root"] as? [String: Any] ?? tree
            let width = max(1, (root["width"] as? NSNumber)?.doubleValue ?? 1080)
            let height = max(1, (root["height"] as? NSNumber)?.doubleValue ?? 1920)
            let ratio = width / height
            let safePlayer = player.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
            var base = URLComponents(url: playerURL, resolvingAgainstBaseURL: false)
            base?.path = "/"
            base?.query = nil
            base?.fragment = nil
            origin = base?.url
            html = """
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
            <style>html,body,#remotion-root{margin:0;width:100%;height:100%;background:#111;color:white;overflow:hidden}
            #remotion-preview{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px}
            #remotion-canvas{width:min(100%,calc(75vh * \(ratio)))!important;max-height:75vh!important;aspect-ratio:\(width)/\(height);border-radius:12px;overflow:hidden}
            #scene-thumbnails{display:flex;max-width:100%;overflow-x:auto;gap:8px;padding:5px}
            </style><div id="remotion-root"></div>
            <script>window.__markcutRevision={compiled:JSON.parse(new TextDecoder().decode(
            Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0))))};</script>
            <script src="\(safePlayer)"></script>
            """
        } catch {
            self.error = error.localizedDescription
        }
    }
}
