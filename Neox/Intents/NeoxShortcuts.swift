import AppIntents

/// Siri phrases for `RunAgentIntent`. Fixed phrases run with the default
/// instruction; note App Intents only allows AppEntity/AppEnum placeholders in
/// phrases, so free-form instructions are set in the Shortcuts editor.
struct NeoxShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .lightBlue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAgentIntent(),
            phrases: [
                "Create a vlog with \(.applicationName)",
                "Make a vlog with \(.applicationName)",
                "Run my agent with \(.applicationName)"
            ],
            shortTitle: "Run Agent Task",
            systemImageName: "wand.and.stars"
        )
    }
}
