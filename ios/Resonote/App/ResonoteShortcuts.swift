import AppIntents

/// Siri, Spotlight, and the Action button's Shortcut option. Every phrase names the
/// app, as App Shortcuts require.
nonisolated struct ResonoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenResonoteIntent(target: .capture),
            phrases: [
                "Note what's playing in \(.applicationName)",
                "Write about this song in \(.applicationName)",
                "\(.applicationName) note",
            ],
            shortTitle: "Note Song",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: OpenResonoteIntent(target: .identify),
            phrases: [
                "Identify a song with \(.applicationName)",
                "What's this song in \(.applicationName)",
            ],
            shortTitle: "Identify Song",
            systemImageName: "shazam.logo"
        )
        AppShortcut(
            intent: NoteSongIntent(),
            phrases: [
                "Note a song in \(.applicationName)",
            ],
            shortTitle: "Note a Song",
            systemImageName: "square.and.pencil"
        )
    }

    /// The closest tile to Resonote's rust accent.
    static let shortcutTileColor: ShortcutTileColor = .tangerine
}
