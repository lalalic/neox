import Testing
import Foundation
@testable import Neox
import CopilotSDK
import CopilotChat

// MARK: - Bootstrap & sendHidden Tests

@Suite("Bootstrap & sendHidden Tests")
@MainActor
struct BootstrapTests {

    // MARK: - sendHidden Behavior

    @Test("sendHidden sets state to working")
    func sendHiddenSetsWorking() async {
        let vm = makeTestVM()
        // Initial state is .disconnected
        #expect(vm.chatState == .disconnected)

        await vm.sendHidden("Test hidden message")

        // Should have set state to .working (MockTransport won't complete anything)
        #expect(vm.chatState == .working)
    }

    @Test("sendHidden with empty text does nothing")
    func sendHiddenEmptyText() async {
        let vm = makeTestVM()
        await vm.sendHidden("")
        #expect(vm.chatState == .disconnected)
    }

    @Test("sendHidden with whitespace-only text does nothing")
    func sendHiddenWhitespaceOnly() async {
        let vm = makeTestVM()
        await vm.sendHidden("   \n  ")
        #expect(vm.chatState == .disconnected)
    }

    @Test("sendHidden does not add user message to messages array")
    func sendHiddenNoVisibleMessage() async {
        let vm = makeTestVM()
        await vm.sendHidden("Hidden prompt for onboarding")

        // sendHidden should NOT add a message to the visible messages array
        // Unlike send() which adds a user message
        #expect(vm.messages.isEmpty)
    }

    @Test("Regular send adds user message but sendHidden does not")
    func sendVsSendHiddenComparison() async {
        let vm1 = makeTestVM()
        vm1.inputText = "Visible message"
        await vm1.send()
        #expect(vm1.messages.count >= 1)
        #expect(vm1.messages.first?.role == .user)

        let vm2 = makeTestVM()
        await vm2.sendHidden("Hidden message")
        #expect(vm2.messages.isEmpty)
    }

    // MARK: - Onboarding Flag

    @Test("Onboarding flag defaults to false")
    func onboardingFlagDefault() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        #expect(defaults.bool(forKey: "hasCompletedOnboarding") == false)
    }

    @Test("Onboarding flag can be set and retrieved")
    func onboardingFlagPersistence() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set(true, forKey: "hasCompletedOnboarding")
        #expect(defaults.bool(forKey: "hasCompletedOnboarding") == true)
    }

    // MARK: - Boarding.md File

    @Test("Boarding.md exists in workspace template")
    func boardingMdExists() throws {
        let workspaceURL = URL(fileURLWithPath: "/Users/chengli/Workspace/free2/neox/workspace")
        let boardingFile = workspaceURL
            .appendingPathComponent(".github")
            .appendingPathComponent("boarding.md")
        #expect(FileManager.default.fileExists(atPath: boardingFile.path))
    }

    @Test("Boarding.md contains onboarding instructions")
    func boardingMdContent() throws {
        let workspaceURL = URL(fileURLWithPath: "/Users/chengli/Workspace/free2/neox/workspace")
        let boardingFile = workspaceURL
            .appendingPathComponent(".github")
            .appendingPathComponent("boarding.md")
        let content = try String(contentsOf: boardingFile, encoding: .utf8)
        #expect(content.lowercased().contains("welcome"))
    }
}
