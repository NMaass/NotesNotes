import ResonoteKit
import SwiftUI
import WidgetKit

/// Home and Lock Screen widget: the current song, a question, and a few tags to
/// start a note with. It shows a cached snapshot (widgets can't watch playback);
/// the app, the refresh button, and each timeline reload keep it current.
struct NowPlayingWidget: Widget {
    static let kind = "NowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("What you’re listening to, ready for a note.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Entry

nonisolated struct NowPlayingEntry: TimelineEntry {
    enum Content: Sendable, Hashable {
        case signedOut
        case nothing
        case track(TrackCard)
    }

    let date: Date
    let content: Content

    /// Raised in the Smart Stack only while a source confirms playback.
    var relevance: TimelineEntryRelevance? {
        guard case .track(let card) = content, card.isPlaying else { return nil }
        return TimelineEntryRelevance(score: 50, duration: 15 * 60)
    }

    /// Where a tap anywhere on the widget goes.
    var url: URL {
        switch content {
        // The install's key tells the app this Identify came from its own widget, so it may listen at once.
        case .nothing: DeepLink.identify(key: IdentifyKey.current).url
        case .signedOut, .track: DeepLink.capture(CapturePreset(origin: "widget")).url
        }
    }
}

/// Everything a widget view shows, precomputed so view bodies stay trivial.
nonisolated struct TrackCard: Sendable, Hashable {
    var title: String
    var artist: String
    /// "Now playing" only while a live source confirms it; otherwise a truthful description.
    var status: String
    var isPlaying: Bool
    /// A downsampled JPEG, at most `WidgetArtwork.maxPixel` on its longest edge.
    var artwork: Data?
    var question: String
    var suggestions: [SuggestionChip]
}

/// A tag that opens capture with it already selected.
nonisolated struct SuggestionChip: Sendable, Hashable, Identifiable {
    var id: String
    var label: String
    var url: URL
}

// MARK: - Provider

nonisolated struct NowPlayingProvider: TimelineProvider {
    /// How long a reported "playing" stays believable without a fresh sample.
    static let playingWindow = NowPlayingTrack.livePlayingWindow
    static let reloadInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> NowPlayingEntry {
        let snapshot = NowPlayingSnapshot.load()
        guard snapshot.track != nil else { return NowPlayingEntryBuilder.sample(at: Date()) }
        return NowPlayingEntryBuilder.entry(for: snapshot, artwork: nil, at: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (NowPlayingEntry) -> Void) {
        let snapshot = NowPlayingSnapshot.load()
        let now = Date()
        if context.isPreview, snapshot.track == nil {
            completion(NowPlayingEntryBuilder.sample(at: now))
            return
        }
        let url = NowPlayingEntryBuilder.artworkURL(for: snapshot)
        if context.isPreview {
            completion(NowPlayingEntryBuilder.entry(for: snapshot, artwork: WidgetArtwork.cached(for: url), at: now))
            return
        }
        Task {
            let artwork = await WidgetArtwork.data(for: url)
            completion(NowPlayingEntryBuilder.entry(for: snapshot, artwork: artwork, at: now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NowPlayingEntry>) -> Void) {
        Task {
            var snapshot = NowPlayingSnapshot.load()
            // The app (or the refresh button) just wrote it; sampling again would only repeat it.
            if snapshot.signedIn, !NowPlayingRefresher.isFresh(snapshot, within: 60) {
                snapshot = await NowPlayingRefresher.refresh(budget: .seconds(5))
            }
            let now = Date()
            let artwork = await WidgetArtwork.data(for: NowPlayingEntryBuilder.artworkURL(for: snapshot))
            let first = NowPlayingEntryBuilder.entry(for: snapshot, artwork: artwork, at: now)
            var entries = [first]
            if first.relevance != nil, let ends = snapshot.track?.playbackClaimEnds, ends > now {
                // Stop claiming "Now playing" once the report is too old to vouch for it.
                entries.append(NowPlayingEntryBuilder.entry(for: snapshot, artwork: artwork, at: ends))
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.reloadInterval))))
        }
    }
}

// MARK: - Building entries

nonisolated enum NowPlayingEntryBuilder {
    static func entry(for snapshot: NowPlayingSnapshot, artwork: Data?, at date: Date) -> NowPlayingEntry {
        guard snapshot.signedIn else { return NowPlayingEntry(date: date, content: .signedOut) }
        guard let track = snapshot.track, !track.title.isEmpty else { return NowPlayingEntry(date: date, content: .nothing) }
        // Older than a few hours, a song is history rather than "now" (the app applies the same rule).
        if track.isStale(at: date) {
            return NowPlayingEntry(date: date, content: .nothing)
        }

        // The rule the app uses too: a live source vouches for its sampling window, a Shazam
        // match or a Shortcut for about one song.
        let confirmedPlaying = track.claimsPlayback(at: date)
        let songId = snapshot.currentResolution?.song?.id
        let wroteBefore = songId.map(snapshot.recentlyNotedSongIds.contains) ?? false

        return NowPlayingEntry(date: date, content: .track(TrackCard(
            title: track.title,
            artist: track.artist,
            status: status(for: track, confirmedPlaying: confirmedPlaying),
            isPlaying: confirmedPlaying,
            artwork: artwork,
            question: wroteBefore ? "Something new to say?" : "Want to write about this?",
            suggestions: chips(from: snapshot.suggestions)
        )))
    }

    /// The cover to show: the source's own, else the matched catalog song's or album's.
    static func artworkURL(for snapshot: NowPlayingSnapshot) -> String? {
        guard let track = snapshot.track else { return nil }
        let resolution = snapshot.currentResolution
        return [track.artworkURL, resolution?.song?.imageUrl, resolution?.album?.imageUrl]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    /// The widget gallery's preview when nothing has been sampled yet.
    static func sample(at date: Date) -> NowPlayingEntry {
        let suggestions = TagSuggestions(lenses: [.feeling], moods: ["nostalgic"])
        return NowPlayingEntry(date: date, content: .track(TrackCard(
            title: "Harvest Moon",
            artist: "Neil Young",
            status: "Now playing",
            isPlaying: false,
            artwork: nil,
            question: "Want to write about this?",
            suggestions: chips(from: suggestions)
        )))
    }

    private static func status(for track: NowPlayingTrack, confirmedPlaying: Bool) -> String {
        if confirmedPlaying { return "Now playing" }
        switch track.source {
        case .appleMusic, .spotify, .lastfm, .listenbrainz: return "Recently played"
        case .shazam: return "Identified"
        case .link: return "Shared"
        case .manual: return "Ready to note"
        }
    }

    /// Up to three tags, mixing a genre, a lens, and a mood when each is available.
    private static func chips(from suggestions: TagSuggestions) -> [SuggestionChip] {
        let genres = suggestions.genres.map { genre in
            SuggestionChip(id: "genre-\(genre.id)", label: genre.name, url: captureURL(CapturePreset(genreId: genre.id, origin: "widget")))
        }
        let lenses = suggestions.lenses.map { lens in
            SuggestionChip(id: "lens-\(lens.rawValue)", label: lens.rawValue, url: captureURL(CapturePreset(lens: lens, origin: "widget")))
        }
        let moods = suggestions.moods.map { mood in
            SuggestionChip(id: "mood-\(mood)", label: mood, url: captureURL(CapturePreset(mood: mood, origin: "widget")))
        }
        var mixed: [SuggestionChip] = []
        for index in 0..<max(genres.count, lenses.count, moods.count) {
            for group in [genres, lenses, moods] where index < group.count {
                mixed.append(group[index])
            }
            if mixed.count >= 3 { break }
        }
        return Array(mixed.prefix(3))
    }

    private static func captureURL(_ preset: CapturePreset) -> URL {
        DeepLink.capture(preset).url
    }
}
