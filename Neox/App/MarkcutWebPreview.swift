import SwiftUI
import WebKit
import UIKit

struct MarkcutWebPreview: UIViewRepresentable {
    let html: String
    let baseURL: URL?
    @Binding var failure: String?
    let retry: Int

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "markcutPreviewError")
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

    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML: String?
        var lastRetry = -1
        var failure: Binding<String?>
        init(failure: Binding<String?>) { self.failure = failure }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async { self.failure.wrappedValue = String(describing: message.body) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.failure.wrappedValue = error.localizedDescription }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.failure.wrappedValue = error.localizedDescription }
        }
    }
}
