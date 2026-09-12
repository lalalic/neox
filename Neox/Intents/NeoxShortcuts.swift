import AppIntents

/// Siri phrases for `RunAgentIntent`. The AppEnum placeholder lets Siri fill
/// today/yesterday/recent/unprocessed-today from the spoken request.
struct NeoxShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .lightBlue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunAgentIntent(),
            phrases: [
                "Create a vlog with \(.applicationName)",
                "Make a vlog with \(.applicationName)",
                "Run my agent with \(.applicationName)",
                "Tell \(.applicationName) what to do"
            ],
            shortTitle: "Run Agent Task",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: AnalyzeMediaIntent(),
            phrases: [
                "Analyze my media with \(.applicationName)",
                "Index my photos with \(.applicationName)"
            ],
            shortTitle: "Analyze Media",
            systemImageName: "eye.trianglebadge.exclamationmark"
        )
    }
}
