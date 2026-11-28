import Foundation
import SwiftUI
import WebKit

/// Scoped, bounded receipt from the selected Master. The renderer receives no
/// credentials, raw Job object or access to the app's authenticated transport.
struct RelayJELPayload {
    let facts: Data
    let generator: String

    init(wire: [String: Any], job: RelayJob) throws {
        guard job.canOpenJEL, wire["schema"] as? String == "relay.jel.v1",
              let facts = wire["job"] as? [String: Any],
              facts["id"] as? String == job.id, facts["repository"] as? String == job.repository,
              facts["state"] as? String == "COMPLETED",
              let tasks = facts["tasks"] as? [[String: Any]], tasks.count <= 500,
              let plans = facts["plans"] as? [[String: Any]], plans.count <= 100,
              let generator = wire["generator"] as? String, generator.utf8.count <= 64_000,
              generator.hasPrefix("function jobJelDiagram(job) {"),
              JSONSerialization.isValidJSONObject(facts) else { throw GatewayRESTError.invalidResponse }
        let bytes = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        guard bytes.count <= 1_000_000 else { throw GatewayRESTError.invalidResponse }
        self.facts = bytes
        self.generator = generator
    }
}

struct RelayJELSheet: View {
    let master: RemoteMCPClient
    let job: RelayJob
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var payload: RelayJELPayload?
    @State private var failure = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let payload {
                    RelayJELWebView(payload: payload, dark: colorScheme == .dark)
                        .accessibilityIdentifier("neoRelayJELChart")
                } else if failure {
                    ContentUnavailableView {
                        Label("JEL unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Could not load the completed Job’s lifecycle. Check the Master connection and version.")
                    } actions: {
                        Button("Retry") { attempt += 1 }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("JEL · \(job.displayIdentity)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: attempt) {
                failure = false
                do {
                    let result = try await master.relayJobJEL(job)
                    try Task.checkCancellation()
                    payload = result
                } catch {
                    if !Task.isCancelled { failure = true }
                }
            }
        }
    }
}

/// The canonical generator is a static Relay asset. Execute it only in a
/// nonpersistent, local document, without native bridges, bearer, cookies,
/// external navigation or network resources. The Mermaid library is bundled.
struct RelayJELWebView: UIViewRepresentable {
    let payload: RelayJELPayload
    let dark: Bool

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let library = Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        configuration.userContentController.addUserScript(WKUserScript(source: library,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        return configuration
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration())
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.dark != dark else { return }
        context.coordinator.dark = dark
        view.loadHTMLString(Self.html(payload: payload, dark: dark), baseURL: nil)
    }

    static func html(payload: RelayJELPayload, dark: Bool) -> String {
        let facts = payload.facts.base64EncodedString()
        let generator = Data(payload.generator.utf8).base64EncodedString()
        let theme = dark ? "dark" : "default"
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <style>html,body{margin:0;padding:0;color-scheme:light dark;font:14px system-ui}
        #tools{position:sticky;top:0;z-index:1;display:flex;gap:12px;align-items:center;padding:10px;background:Canvas;color:CanvasText}
        button{font:inherit;padding:8px 16px;border:1px solid GrayText;border-radius:8px;color:CanvasText;background:Canvas}
        #chart{padding:12px;min-width:100%;box-sizing:border-box;width:max-content}#chart svg{display:block;max-width:none!important;height:auto}
        #error{padding:16px;color:CanvasText} </style></head><body>
        <div id="tools"><button id="minus" aria-label="Zoom out">−</button><button id="fit">Fit</button><button id="plus" aria-label="Zoom in">+</button><span id="zoom"></span></div>
        <div id="error" role="status">Rendering JEL…</div><div id="chart"></div>
        <script>
        (async function(){
          const error=document.getElementById('error');
          try {
            const decode=value=>new TextDecoder().decode(Uint8Array.from(atob(value),c=>c.charCodeAt(0)));
            const job=JSON.parse(decode('\(facts)'));
            // Execute the static generator only after the restrictive CSP is in force.
            const generator=document.createElement('script');generator.textContent=decode('\(generator)');document.head.appendChild(generator);
            if(typeof jobJelDiagram!=='function'||typeof mermaid==='undefined')throw Error('renderer unavailable');
            const source=jobJelDiagram(job);
            mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'\(theme)',flowchart:{htmlLabels:false,useMaxWidth:false},maxTextSize:160000,maxEdges:3000});
            const result=await mermaid.render('neo-jel',source);
            const chart=document.getElementById('chart');chart.innerHTML=result.svg;
            const svg=chart.querySelector('svg');if(!svg)throw Error('chart unavailable');
            const width=svg.viewBox.baseVal.width||svg.getBoundingClientRect().width;
            const height=svg.viewBox.baseVal.height||svg.getBoundingClientRect().height;
            if(!Number.isFinite(width)||width<=0||!Number.isFinite(height)||height<=0)throw Error('invalid chart');
            let scale=1;
            const resize=value=>{scale=Math.min(6,Math.max(.05,value));svg.style.width=width*scale+'px';svg.style.height=height*scale+'px';document.getElementById('zoom').textContent=Math.round(scale*100)+'%';};
            const fit=()=>resize(Math.min(1,(innerWidth-24)/width));
            document.getElementById('minus').onclick=()=>resize(scale/1.25);
            document.getElementById('plus').onclick=()=>resize(scale*1.25);
            document.getElementById('fit').onclick=fit;
            error.hidden=true;fit();document.body.dataset.jelRendered='true';
          }catch(e){error.textContent='JEL diagram unavailable.';}
        })();
        </script></body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var dark: Bool?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.scheme == "about" && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }
    }
}
