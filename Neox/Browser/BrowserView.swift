import SwiftUI
import WebKitAgent

struct BrowserView: View {
    @State private var urlText: String = ""
    @State private var manager = WebViewManager()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Enter URL...", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .onSubmit { navigate() }
                    
                    Button("Go") { navigate() }
                        .disabled(urlText.isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                
                WebAgentView(manager: manager)
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func navigate() {
        let urlString = urlText.hasPrefix("http") ? urlText : "https://\(urlText)"
        Task {
            _ = try? await manager.navigate(to: urlString)
        }
    }
}
