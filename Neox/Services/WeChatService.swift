import SwiftUI
import WebKitAgent
import WebKit

// MARK: - Persistence Types

/// Global WeChat service configuration (persisted in UserDefaults).
struct WeChatServiceConfig: Codable {
    var enabled: Bool = false
}

/// Contact bindings for a routing context (main chat or a project).
struct WeChatContactBindings: Codable, Equatable {
    var contacts: [BoundContact] = []
    var routingActive: Bool = true

    struct BoundContact: Codable, Identifiable, Equatable {
        let id: String        // contactUserName
        let name: String      // display name
        let isRoom: Bool
    }
}

// MARK: - WeChatService

/// Manages the WeChat channel lifecycle, contact bindings, and message forwarding.
///
/// Owns a `WeChatChannel` with its own private WKWebView — independent of the globe browser.
@MainActor
final class WeChatService: ObservableObject {

    // MARK: - Published State

    @Published var config: WeChatServiceConfig {
        didSet { saveConfig() }
    }

    @Published private(set) var channel: WeChatChannel?

    /// Bindings for "main chat" (no project selected / all-projects).
    @Published var mainBindings: WeChatContactBindings {
        didSet { saveBindings() }
    }

    /// Per-project bindings keyed by project name.
    @Published var projectBindings: [String: WeChatContactBindings] = [:] {
        didSet { saveBindings() }
    }

    // MARK: - Derived State

    var isOnline: Bool { channel?.state == .ready }
    var loggedInUser: WeChatUser? { channel?.loggedInUser }
    var contacts: [WeChatContact] { channel?.contacts ?? [] }
    @Published var channelState: WeChatChannelState = .disconnected
    var qrCodeURL: String? { channel?.qrCodeURL }

    func statusColor(for project: String?) -> Color {
        guard config.enabled else { return .gray }
        guard isOnline else { return .gray }
        let bindings = getBindings(for: project)
        if !bindings.routingActive || bindings.contacts.isEmpty { return .yellow }
        return .green
    }

    // MARK: - Private

    private let defaults: UserDefaults
    private let bindingsFileURL: URL

    /// Hidden window to host the WKWebView (required on-device).
    private var hiddenWindow: UIWindow?

    private static let configKey = "wechat_service_config"
    private static let bindingsFileName = "wechat-bindings.json"

    // MARK: - Init

    init(workspaceURL: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bindingsFileURL = workspaceURL
            .appendingPathComponent(".neo", isDirectory: true)
            .appendingPathComponent(Self.bindingsFileName)

        // Load persisted config
        if let data = defaults.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(WeChatServiceConfig.self, from: data) {
            self.config = saved
        } else {
            self.config = WeChatServiceConfig()
        }

        // Load persisted bindings (must initialize stored props before calling methods)
        let fileURL = self.bindingsFileURL
        var loaded: [String: WeChatContactBindings] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let dict = try? JSONDecoder().decode([String: WeChatContactBindings].self, from: data) {
            loaded = dict
        }
        self.mainBindings = loaded.removeValue(forKey: "__main__") ?? WeChatContactBindings()
        self.projectBindings = loaded

        // Auto-start if previously enabled
        if config.enabled {
            enable()
        }
    }

    // MARK: - Enable / Disable

    func enable() {
        guard channel == nil else { return }
        let ch = WeChatChannel()
        ch.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.channelState = newState
                self?.objectWillChange.send()
            }
        }
        self.channel = ch

        // WKWebView must be in a UIWindow hierarchy to load content on-device.
        // On iOS 13+, windows must be associated with a UIWindowScene.
        // The webView needs a reasonable frame for WebKit to render content.
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds  // Full screen for proper rendering
            window.windowLevel = .init(rawValue: -1000)  // Far below everything
            window.isUserInteractionEnabled = false
            window.alpha = 0.01  // Near-invisible (alpha=0 causes iOS to skip rendering)
            let vc = UIViewController()
            vc.view.addSubview(ch.webView)
            // Keep webView at its original 1280×900 for proper wx.qq.com rendering
            ch.webView.frame = CGRect(x: 0, y: 0, width: 1280, height: 900)
            window.rootViewController = vc
            window.isHidden = false
            self.hiddenWindow = window
        }

        ch.start()
        config.enabled = true
    }

    func disable() {
        channel?.destroy()
        channel = nil
        channelState = .disconnected
        hiddenWindow?.isHidden = true
        hiddenWindow = nil
        config.enabled = false
    }

    /// Restart the channel after being kicked off / session expired.
    /// Triggers full QR login flow again (the QR sheet auto-shows via channelState observation).
    func restart() {
        channel?.restart()
    }

    // MARK: - Routing

    func getBindings(for project: String?) -> WeChatContactBindings {
        if let project, let bindings = projectBindings[project] {
            return bindings
        }
        return mainBindings
    }

    func setBindings(_ bindings: WeChatContactBindings, for project: String?) {
        if let project {
            projectBindings[project] = bindings
        } else {
            mainBindings = bindings
        }
    }

    func toggleRouting(for project: String?) {
        var bindings = getBindings(for: project)
        bindings.routingActive.toggle()
        setBindings(bindings, for: project)
    }

    func isRoutingActive(for project: String?) -> Bool {
        let bindings = getBindings(for: project)
        return bindings.routingActive && !bindings.contacts.isEmpty
    }

    /// Forward a message to all bound contacts for the given context.
    func forward(message: String, project: String?) async {
        guard config.enabled, isOnline else { return }
        let bindings = getBindings(for: project)
        guard bindings.routingActive else { return }
        for contact in bindings.contacts {
            _ = await channel?.sendMessage(to: contact.id, content: message)
        }
    }

    // MARK: - Persistence

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.configKey)
        }
    }

    private func saveBindings() {
        var all = projectBindings
        all["__main__"] = mainBindings
        let dir = bindingsFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: bindingsFileURL, options: .atomic)
        }
    }

    private func loadBindings() -> [String: WeChatContactBindings] {
        guard let data = try? Data(contentsOf: bindingsFileURL),
              let dict = try? JSONDecoder().decode([String: WeChatContactBindings].self, from: data)
        else { return [:] }
        return dict
    }
}
