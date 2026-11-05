import SwiftUI
import WebKit
import UIKit

struct MarkcutPlaybackPosition: Equatable {
    let sceneID: String?
    let timeSeconds: Double
}

struct MarkcutWebPreview: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    @Binding var failure: String?
    @Binding var playbackPosition: MarkcutPlaybackPosition?
    let retry: Int

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "markcutPreviewError")
        configuration.userContentController.add(context.coordinator, name: "markcutPlaybackPosition")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        // Let the review sheet show around letterboxed landscape videos instead
        // of presenting an oversized black rectangle as though it were the film.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = view.backgroundColor
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.failure = $failure
        guard context.coordinator.lastHTML != html || context.coordinator.lastRetry != retry else { return }
        context.coordinator.lastHTML = html
        context.coordinator.lastRetry = retry
        failure = nil
        view.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure, playbackPosition: $playbackPosition) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML: String?
        var lastRetry = -1
        var failure: Binding<String?>
        var playbackPosition: Binding<MarkcutPlaybackPosition?>
        init(failure: Binding<String?>, playbackPosition: Binding<MarkcutPlaybackPosition?>) {
            self.failure = failure
            self.playbackPosition = playbackPosition
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "markcutPlaybackPosition",
               let value = message.body as? [String: Any],
               let seconds = value["timeSeconds"] as? Double,
               seconds.isFinite && seconds >= 0 {
                let sceneID = value["sceneId"] as? String
                DispatchQueue.main.async {
                    self.playbackPosition.wrappedValue = MarkcutPlaybackPosition(
                        sceneID: sceneID, timeSeconds: seconds)
                }
            } else if message.name == "markcutPreviewError" {
                DispatchQueue.main.async { self.failure.wrappedValue = String(describing: message.body) }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.failure.wrappedValue = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.failure.wrappedValue = error.localizedDescription }
        }
    }
}
