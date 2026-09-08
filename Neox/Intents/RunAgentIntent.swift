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

    // @Parameter's default must be a compile-time literal — keep in sync with
    // AgentHandoff.defaultInstruction (used by the status-screen preview).
    @Parameter(title: "Instruction", default: "Create a vlog from yesterday's photos and videos")
    var instruction: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        // Advertise a live endpoint: iOS may have torn the listener down.
        let bridge = ServerController.shared
        bridge.ensureRunning()

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

        return .result(
            value: message,
            dialog: "Instruction and MCP URL ready — copied to clipboard for the agent chat.\(photosNote)"
        )
    }
}
