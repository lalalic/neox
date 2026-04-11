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
        let id: String        // contactUserName (e.g. @@abc123 for rooms, @user456 for 1:1)
        let name: String      // display name
        let isRoom: Bool
        var weight: Int?      // 1:1 sender weight (default 50), nil for rooms
        var autoReply: Bool?  // Scenario 2: auto-reply as owner
        var members: [String: WeChatMember]?  // Room member weights (rooms only)
    }
}

/// A room member with a decision weight.
struct WeChatMember: Codable, Equatable {
    let name: String
    var weight: Int    // 0–100
}

// MARK: - WeChatService

/// Manages the WeChat channel lifecycle, contact bindings, and message forwarding.
///
/// Owns a `WeChatBridge` with its own private WKWebView — independent of the globe browser.
@MainActor
final class WeChatService: ObservableObject {

    let workspaceURL: URL

    // MARK: - Published State

    @Published var config: WeChatServiceConfig {
        didSet { saveConfig() }
    }

    @Published private(set) var channel: WeChatBridge?

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

    /// Callback for incoming messages. Set by AgentCoordinator to wire the router.
    var onIncomingMessage: ((WeChatMessage) -> Void)?

    /// Callback when WeChat channel becomes ready. Used to create/resume wired project sessions.
    var onReady: (() -> Void)?

    private static let configKey = "wechat_service_config"
    private static let bindingsFileName = "wechat-bindings.json"

    // MARK: - Init

    init(workspaceURL: URL, defaults: UserDefaults = .standard) {
        self.workspaceURL = workspaceURL
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

        // Build contact→project lookup
        rebuildContactLookup()

        // Auto-start if previously enabled
        if config.enabled {
            enable()
        }
    }

    // MARK: - Enable / Disable

    func enable() {
        guard channel == nil else { return }

        // Default WKWebsiteDataStore persists cookies across sessions
        // so the user stays logged in after app restart.
        startChannel()
    }

    private func startChannel() {
        guard channel == nil else { return }
        let ch = WeChatBridge()
        ch.onStateChange = { [weak self] newState in
            Task { @MainActor in
                self?.channelState = newState
                self?.objectWillChange.send()
                // Notify coordinator when channel is fully ready
                if newState == .ready {
                    self?.onReady?()
                }
            }
        }
        self.channel = ch

        // Wire incoming message handler for bidirectional routing
        ch.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.onIncomingMessage?(message)
            }
        }

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
        teardown()
        config.enabled = false
    }

    /// Restart the channel after being kicked off / session expired.
    /// Creates a fresh WKWebView + channel with a clean data store.
    func restart() {
        teardown()
        enable()
    }

    /// Internal teardown — destroys channel and window without disabling the service.
    private func teardown() {
        channel?.destroy()
        channel = nil
        channelState = .disconnected
        hiddenWindow?.isHidden = true
        hiddenWindow = nil
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
        rebuildContactLookup()
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
    func forward(message: String, project: String?, watermark: Bool = true) async {
        guard config.enabled, isOnline else { return }
        let bindings = getBindings(for: project)
        guard bindings.routingActive else { return }
        for contact in bindings.contacts {
            _ = await channel?.sendMessage(to: contact.id, content: message, watermark: watermark)
        }
    }

    /// Send a message to a specific contact (used by bidirectional routing).
    func sendToContact(_ contactId: String, message: String, watermark: Bool = true) async {
        guard config.enabled, isOnline else { return }
        _ = await channel?.sendMessage(to: contactId, content: message, watermark: watermark) ?? false
    }

    /// Get members of a room (group chat).
    func getRoomMembers(roomId: String) async -> [WeChatRoomMember] {
        guard isOnline else { return [] }
        return await channel?.getRoomMembers(roomId: roomId) ?? []
    }

    // MARK: - Contact → Project Lookup

    /// In-memory map: contactId → projectId. Built from all project bindings.
    private(set) var contactLookup: [String: String] = [:]

    /// Rebuild the contact→project lookup from all project bindings.
    /// Called on startup and when bindings change.
    func rebuildContactLookup() {
        var lookup: [String: String] = [:]
        for (projectId, bindings) in projectBindings {
            guard bindings.routingActive else { continue }
            for contact in bindings.contacts {
                lookup[contact.id] = projectId
            }
        }
        contactLookup = lookup
    }

    /// Look up which project a contact is bound to (if any).
    func projectForContact(_ contactId: String) -> String? {
        contactLookup[contactId]
    }

    /// Get the sender weight for a contact in a project's bindings.
    /// Owner (logged-in user) always gets weight 100 in room messages.
    func senderWeight(contactId: String, senderId: String?, project: String?) -> Int {
        // Owner always has full authority
        if let senderId, let owner = loggedInUser,
           senderId == owner.userName || senderId == owner.id {
            return 100
        }

        let bindings = getBindings(for: project)
        guard let contact = bindings.contacts.first(where: { $0.id == contactId }) else {
            return 0
        }
        // Room: look up member weight
        if contact.isRoom, let senderId, let members = contact.members {
            return members[senderId]?.weight ?? 0
        }
        // 1:1: use contact weight (default 50)
        return contact.weight ?? 50
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
