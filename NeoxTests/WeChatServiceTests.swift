import Testing
import Foundation
@testable import Neox

@Suite("WeChatService")
@MainActor
struct WeChatServiceTests {

    // MARK: - Helpers

    /// Create a temporary workspace directory for each test.
    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeChatServiceTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeService(dir: URL? = nil, defaults: UserDefaults? = nil) -> WeChatService {
        let ws = dir ?? makeTempDir()
        let ud = defaults ?? UserDefaults(suiteName: UUID().uuidString)!
        return WeChatService(workspaceURL: ws, defaults: ud)
    }

    // MARK: - Config Persistence

    @Test("Default config is disabled")
    func defaultConfigDisabled() {
        let svc = makeService()
        #expect(svc.config.enabled == false)
        #expect(svc.channel == nil)
    }

    @Test("Config persists across instances")
    func configPersistence() {
        let dir = makeTempDir()
        let ud = UserDefaults(suiteName: UUID().uuidString)!
        let svc1 = WeChatService(workspaceURL: dir, defaults: ud)
        svc1.config.enabled = true // Note: this sets config but doesn't actually start channel in test
        // Reload
        let svc2 = WeChatService(workspaceURL: dir, defaults: ud)
        #expect(svc2.config.enabled == true)
    }

    // MARK: - Bindings

    @Test("Main bindings are empty by default")
    func mainBindingsDefault() {
        let svc = makeService()
        #expect(svc.mainBindings.contacts.isEmpty)
        #expect(svc.mainBindings.routingActive == true)
    }

    @Test("Set and get main bindings")
    func setMainBindings() {
        let svc = makeService()
        var b = WeChatContactBindings()
        b.contacts = [.init(id: "user1", name: "Alice", isRoom: false)]
        svc.setBindings(b, for: nil)
        let got = svc.getBindings(for: nil)
        #expect(got.contacts.count == 1)
        #expect(got.contacts[0].name == "Alice")
    }

    @Test("Set and get project bindings")
    func setProjectBindings() {
        let svc = makeService()
        var b = WeChatContactBindings()
        b.contacts = [.init(id: "room1", name: "Dev Room", isRoom: true)]
        svc.setBindings(b, for: "myProject")
        let got = svc.getBindings(for: "myProject")
        #expect(got.contacts.count == 1)
        #expect(got.contacts[0].isRoom == true)
    }

    @Test("Project bindings fall back to main if not set")
    func projectFallsBackToMain() {
        let svc = makeService()
        var b = WeChatContactBindings()
        b.contacts = [.init(id: "u1", name: "Bob", isRoom: false)]
        svc.setBindings(b, for: nil)
        let got = svc.getBindings(for: "unsetProject")
        #expect(got.contacts.count == 1)
        #expect(got.contacts[0].name == "Bob")
    }

    @Test("Toggle routing")
    func toggleRouting() {
        let svc = makeService()
        #expect(svc.mainBindings.routingActive == true)
        svc.toggleRouting(for: nil)
        #expect(svc.mainBindings.routingActive == false)
        svc.toggleRouting(for: nil)
        #expect(svc.mainBindings.routingActive == true)
    }

    @Test("Toggle routing for project")
    func toggleProjectRouting() {
        let svc = makeService()
        var b = WeChatContactBindings()
        b.contacts = [.init(id: "u1", name: "X", isRoom: false)]
        svc.setBindings(b, for: "p1")
        #expect(svc.getBindings(for: "p1").routingActive == true)
        svc.toggleRouting(for: "p1")
        #expect(svc.getBindings(for: "p1").routingActive == false)
    }

    @Test("isRoutingActive requires contacts")
    func routingRequiresContacts() {
        let svc = makeService()
        // No contacts bound — not active even though routingActive is true
        #expect(svc.isRoutingActive(for: nil) == false)
        var b = WeChatContactBindings()
        b.contacts = [.init(id: "u1", name: "X", isRoom: false)]
        svc.setBindings(b, for: nil)
        #expect(svc.isRoutingActive(for: nil) == true)
    }

    // MARK: - Bindings Persistence

    @Test("Bindings persist to file")
    func bindingsPersistence() {
        let dir = makeTempDir()
        let ud = UserDefaults(suiteName: UUID().uuidString)!
        let svc1 = WeChatService(workspaceURL: dir, defaults: ud)
        var b = WeChatContactBindings()
        b.contacts = [.init(id: "u1", name: "Alice", isRoom: false)]
        svc1.setBindings(b, for: nil)
        var pb = WeChatContactBindings()
        pb.contacts = [.init(id: "r1", name: "Room1", isRoom: true)]
        svc1.setBindings(pb, for: "proj")

        // Reload
        let svc2 = WeChatService(workspaceURL: dir, defaults: ud)
        #expect(svc2.mainBindings.contacts.count == 1)
        #expect(svc2.mainBindings.contacts[0].name == "Alice")
        #expect(svc2.projectBindings["proj"]?.contacts.count == 1)
        #expect(svc2.projectBindings["proj"]?.contacts[0].name == "Room1")
    }

    // MARK: - Status Color

    @Test("Status color when disabled")
    func statusColorDisabled() {
        let svc = makeService()
        // Disabled service → gray
        #expect(svc.statusColor(for: nil) == .gray)
    }

    @Test("Status color when enabled but offline")
    func statusColorOffline() {
        let svc = makeService()
        svc.config.enabled = true
        // Channel is nil (offline) → gray
        #expect(svc.statusColor(for: nil) == .gray)
    }

    // MARK: - Enable / Disable

    @Test("Enable creates channel")
    func enableCreatesChannel() {
        let svc = makeService()
        #expect(svc.channel == nil)
        svc.enable()
        #expect(svc.channel != nil)
        #expect(svc.config.enabled == true)
    }

    @Test("Disable destroys channel")
    func disableDestroysChannel() {
        let svc = makeService()
        svc.enable()
        svc.disable()
        #expect(svc.channel == nil)
        #expect(svc.config.enabled == false)
    }

    @Test("Double enable is no-op")
    func doubleEnable() {
        let svc = makeService()
        svc.enable()
        let ch1 = svc.channel
        svc.enable()
        #expect(svc.channel === ch1) // Same instance
    }
}
