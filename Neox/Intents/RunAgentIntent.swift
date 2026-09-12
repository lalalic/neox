import AppIntents
import Photos
import UIKit

/// Siri/Shortcuts entry point: hand the user's instruction plus this phone's
/// MCP endpoint to the Codex agent session. The intent does not resolve dates
/// or inspect media — it composes the message via `AgentHandoff`, copies it to
/// the clipboard as a manual fallback, and returns it as the shortcut's output
/// so Shortcuts/Codex Remote can deliver it to the agent chat.
///
/// Reliability for unattended runs (Wi-Fi automations): the app is brought to
/// the foreground before `perform` executes — backgrounded intents risk the
/// MCP listener being suspended, and a foregrounded status screen doubles as
/// visible confirmation that the automation fired.
struct RunAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Agent Task"
    static var description: IntentDescription {
        IntentDescription(
            "Sends your instruction, plus this phone's media MCP server URL, to the Codex agent.",
            categoryName: "Agent"
        )
    }
    static let openAppWhenRun = true

    // Keep the complete user wording intact. Siri/Shortcuts is the courier;
    // Neoy/Astra interprets dates, recency, and workflow constraints.
    @Parameter(title: "Instruction", default: "Create a vlog from today's photos and videos")
    var instruction: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Advertise a live endpoint: iOS may have torn the listener down.
        let bridge = ServerController.shared
        bridge.ensureRunning()

        // ensureRunning() restarts Bonjour browse; give mDNS a beat to
        // populate so a freshly-started bridge is visible before we check.
        if bridge.discoveredBridges.isEmpty {
            try? await Task.sleep(for: .milliseconds(1500))
        }

        // Photos preflight: an unattended automation must not discover a
        // permission wall only when the agent later calls media.search.
        var photosNote = ""
        let photosStatus = bridge.photosStatus == .notDetermined
            ? await bridge.requestPhotosAccess()
            : bridge.photosStatus
        switch photosStatus {
        case .authorized, .limited:
            break
        case .notDetermined:
            photosNote = " Photos permission prompt will appear — approve it once."
        default:
            photosNote = " Warning: Photos access is denied — allow it in Settings › Privacy & Security › Photos."
        }

        let message = AgentHandoff.message(instruction: instruction, mcpURL: bridge.mcpURL)
        UIPasteboard.general.string = message

        // Preferred path: discover the desktop bridge over Bonjour and POST
        // the handoff directly — no Shortcut hop. Falls back to clipboard +
        // output value when no bridge is on the LAN.
        let dialog: String
        switch await AgentBridge.handoff(message, discovered: bridge.discoveredBridges,
                                         preferred: bridge.preferredBridge) {
        case .posted:
            dialog = "Handed off to the agent bridge."
        case .bridgeNotFound:
            dialog = "No agent bridge found — instruction and MCP URL copied to the clipboard; paste them into the agent chat."
        case .failed(let why):
            dialog = "Bridge error (\(why)) — message copied to the clipboard as fallback."
        }

        return .result(
            value: message,
            dialog: IntentDialog(stringLiteral: dialog)
        )
    }
}
