import AppIntents
import ResonoteKit

// Compiled into both the app and the widget extension. Controls can open the app
// only when their OpenIntent exists in both targets, and widget buttons run their
// intent in the extension's process.

/// Where a control, the Action button, or an App Shortcut takes the person.
nonisolated enum CaptureTarget: String, AppEnum {
    case capture
    case identify

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Action"

    static let caseDisplayRepresentations: [CaptureTarget: DisplayRepresentation] = [
        .capture: DisplayRepresentation(title: "Note what’s playing", image: .init(systemName: "music.note.list")),
        .identify: DisplayRepresentation(title: "Identify a song", image: .init(systemName: "shazam.logo")),
    ]
}

/// Opens Resonote on capture or identify. The system opens the app for an
/// `OpenIntent`; the app routes it in `appIntentRouting()` before it comes forward.
struct OpenResonoteIntent: OpenIntent, TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "Open Resonote"
    static let description = IntentDescription("Write about what’s playing, or identify a song first.")

    @Parameter(title: "Action")
    var target: CaptureTarget

    init() {
        target = .capture
    }

    init(target: CaptureTarget) {
        self.target = target
    }
}

#if RESONOTE_APP
/// Hands a song to Resonote and opens capture for it. Exists so a person's own
/// Shortcut can chain Apple's Shazam action (which hears audio playing in
/// headphones) into Resonote. App only: it always opens the app, and an extension
/// can't run foreground intents.
struct NoteSongIntent: AppIntent, TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "Note a Song"
    static let description = IntentDescription("Open Resonote ready to write about a song you name.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Artist")
    var artist: String

    @Parameter(title: "Apple Music ID")
    var appleMusicID: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Note \(\.$title) by \(\.$artist)") {
            \.$appleMusicID
        }
    }

    init() {}

    init(title: String, artist: String, appleMusicID: String? = nil) {
        self.title = title
        self.artist = artist
        self.appleMusicID = appleMusicID
    }

    /// The song as a now-playing track, or nil when no title was given.
    var track: NowPlayingTrack? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return nil }
        let id = appleMusicID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return NowPlayingTrack(
            title: cleanTitle,
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            appleMusicId: id.isEmpty ? nil : id,
            source: .manual,
            isPlaying: true
        )
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
#endif

/// The widget's refresh button. Runs in the widget extension, samples every source
/// it can reach, and writes the shared snapshot; WidgetKit reloads the timeline
/// after any button intent, without spending the daily reload budget.
struct RefreshNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Now Playing"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    init() {}

    func perform() async throws -> some IntentResult {
        _ = await NowPlayingRefresher.refresh(budget: .seconds(8))
        return .result()
    }
}
