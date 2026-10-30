import Foundation

/// One song the person played recently, from whichever source remembers it. The
/// capture sheet's "Recently played" row is a list of these (docs/IOS_NOW_PLAYING.md):
/// history is the primary source, and a live "now" only promotes one row.
public struct RecentPlay: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// Picked in the Journaling Suggestions sheet (`GenericMedia` or `Song`).
        case journalingSuggestion = "journaling-suggestion"
        /// MusicKit `MusicRecentlyPlayedRequest<Song>`: in order, but undated.
        case appleMusicRecent = "apple-music-recent"
        /// A library song's `lastPlayedDate`.
        case libraryLastPlayed = "library-last-played"
        case lastfm
        case listenbrainz
        /// The Music app's player, sampled now.
        case musicApp = "music-app"
        case shazam
        case link

        public var label: String {
            switch self {
            case .journalingSuggestion: "Journal suggestion"
            case .appleMusicRecent, .libraryLastPlayed, .musicApp: "Apple Music"
            case .lastfm: "Last.fm"
            case .listenbrainz: "ListenBrainz"
            case .shazam: "Shazam"
            case .link: "Shared link"
            }
        }

        /// The `NowPlayingTrack` source the backend understands for this one.
        public var trackSource: NowPlayingTrack.Source {
            switch self {
            case .appleMusicRecent, .libraryLastPlayed, .musicApp: .appleMusic
            case .lastfm: .lastfm
            case .listenbrainz: .listenbrainz
            case .shazam: .shazam
            case .link: .link
            case .journalingSuggestion: .manual
            }
        }
    }

    public var title: String
    public var artist: String
    public var album: String?
    /// When it was played (a scrobble's start, a suggestion's date), or when a source
    /// sampled it playing. Nil for undated history such as Apple Music's recent list.
    public var playedAt: Date?
    public var source: Source
    /// A live source says it is playing right now.
    public var isPlaying: Bool
    public var durationMs: Int?
    public var isrc: String?
    public var mbid: String?
    public var appleMusicId: String?
    public var spotifyId: String?
    public var youtubeId: String?
    public var url: String?
    public var artworkURL: String?
    /// The app that played it, when the source says (Journaling Suggestions does).
    public var appName: String?

    public init(title: String, artist: String, album: String? = nil, playedAt: Date?, source: Source, isPlaying: Bool = false, durationMs: Int? = nil, isrc: String? = nil, mbid: String? = nil, appleMusicId: String? = nil, spotifyId: String? = nil, youtubeId: String? = nil, url: String? = nil, artworkURL: String? = nil, appName: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.playedAt = playedAt
        self.source = source
        self.isPlaying = isPlaying
        self.durationMs = durationMs
        self.isrc = isrc
        self.mbid = mbid
        self.appleMusicId = appleMusicId
        self.spotifyId = spotifyId
        self.youtubeId = youtubeId
        self.url = url
        self.artworkURL = artworkURL
        self.appName = appName
    }

    /// A track from a now-playing source or `GET /api/now-playing`'s `recent` list.
    public init(track: NowPlayingTrack) {
        let source: Source = switch track.source {
        case .appleMusic: .musicApp
        case .lastfm: .lastfm
        case .listenbrainz: .listenbrainz
        case .shazam: .shazam
        case .spotify, .link, .manual: .link
        }
        self.init(title: track.title, artist: track.artist, album: track.album, playedAt: track.observedDate, source: source, isPlaying: track.isPlaying, durationMs: track.durationMs, isrc: track.isrc, mbid: track.mbid, appleMusicId: track.appleMusicId, spotifyId: track.spotifyId, youtubeId: track.youtubeId, url: track.url, artworkURL: track.artworkURL)
    }

    /// The shape `/api/music/resolve` takes. An undated play is observed `now`, but
    /// never claims playback unless `isPlaying`.
    public func track(now: Date = Date()) -> NowPlayingTrack {
        NowPlayingTrack(title: title, artist: artist, album: album, durationMs: durationMs, artworkURL: artworkURL, isrc: isrc, mbid: mbid, spotifyId: spotifyId, appleMusicId: appleMusicId, youtubeId: youtubeId, url: url, source: source.trackSource, isPlaying: isPlaying, observedAt: ResonoteDate.string(from: playedAt ?? now))
    }

    /// Normalized artist and title, shared with `NowPlayingTrack.identity`.
    public var matchKey: String { TrackText.matchKey(artist: artist, title: title) }

    /// Unique within a ranked list: the song plus when (or, undated, where) it was played.
    public var id: String {
        let when = playedAt.map { String(Int($0.timeIntervalSince1970)) } ?? source.rawValue
        return "\(matchKey)@\(when)"
    }

    /// Whether `other` is the same song: equal ISRCs when both have one, else equal text.
    public func isSameSong(as other: RecentPlay) -> Bool {
        if let isrc, let otherIsrc = other.isrc, !isrc.isEmpty, !otherIsrc.isEmpty {
            return isrc.uppercased() == otherIsrc.uppercased()
        }
        return matchKey == other.matchKey
    }

    /// How long the play lasted, or about one song when the source doesn't say.
    var length: TimeInterval {
        durationMs.map { TimeInterval($0) / 1000 } ?? NowPlayingTrack.assumedSongLength
    }
}

/// Recent plays merged across sources, newest first, with the one to pre-select.
public struct RecentPlayList: Sendable, Hashable {
    /// Two reports of one song closer together than this are the same play.
    public static let samePlayWindow: TimeInterval = 10 * 60

    /// The playing row first (at most one), then dated plays newest first, then undated
    /// ones in the order their source gave.
    public var plays: [RecentPlay]
    /// The likeliest song: the playing row, else the newest dated play if it is not
    /// stale (`NowPlayingTrack.staleAfter`). Never an undated play: no one can say when it was.
    public var preselected: RecentPlay?

    public init(plays: [RecentPlay] = [], preselected: RecentPlay? = nil) {
        self.plays = plays
        self.preselected = preselected
    }

    /// Pre-select one: playing beats recent, newer beats older; a live source only
    /// promotes one row.
    ///
    /// - Reports of the same song that are one play (both playing, within
    ///   `samePlayWindow`, or one undated) merge into one row; the playing, then dated,
    ///   then newer report wins, and the other fills its missing details.
    /// - Only the newest report that still claims playback at `now`
    ///   (`NowPlayingTrack.claimsPlayback`) stays playing; every other row is history.
    public static func rank(_ input: [RecentPlay], now: Date = Date(), limit: Int = 10) -> RecentPlayList {
        // A playing report whose claim has lapsed is just a recent play.
        let reports = input.map { play -> RecentPlay in
            var play = play
            if play.isPlaying, !play.track(now: now).claimsPlayback(at: now) { play.isPlaying = false }
            return play
        }

        var merged: [RecentPlay] = []
        for play in reports.sorted(by: precedes) {
            if let index = merged.firstIndex(where: { isSamePlay($0, play) }) {
                merged[index] = filling(merged[index], from: play)
            } else {
                merged.append(play)
            }
        }

        // One live row at most: the newest playing report.
        var promoted = false
        for index in merged.indices where merged[index].isPlaying {
            if promoted { merged[index].isPlaying = false } else { promoted = true }
        }

        let playing = merged.filter(\.isPlaying)
        let dated = merged.filter { !$0.isPlaying && $0.playedAt != nil }
            .sorted { ($0.playedAt ?? .distantPast) > ($1.playedAt ?? .distantPast) }
        let undated = merged.filter { !$0.isPlaying && $0.playedAt == nil }
        let plays = Array((playing + dated + undated).prefix(max(0, limit)))

        // The first row is the playing one or the newest dated play, if there is either.
        let preselected = plays.first.flatMap { play -> RecentPlay? in
            if play.isPlaying { return play }
            guard let playedAt = play.playedAt, now.timeIntervalSince(playedAt) <= NowPlayingTrack.staleAfter else { return nil }
            return play
        }
        return RecentPlayList(plays: plays, preselected: preselected)
    }

    /// The play a note written at `date` is about, for writing first and attaching
    /// later: the latest play that started by `date` and was still going (its length,
    /// or about one song, plus a minute's grace). A playing row covers until its claim ends.
    public static func play(covering date: Date, in plays: [RecentPlay]) -> RecentPlay? {
        let grace: TimeInterval = 60
        return plays
            .filter { play in
                guard let start = play.playedAt, start <= date.addingTimeInterval(grace) else { return false }
                let end = play.isPlaying
                    ? (play.track().playbackClaimEnds ?? start.addingTimeInterval(play.length))
                    : start.addingTimeInterval(play.length)
                return date <= end.addingTimeInterval(grace)
            }
            .max { ($0.playedAt ?? .distantPast) < ($1.playedAt ?? .distantPast) }
    }

    /// Merge order: playing first, then dated before undated, then newer first.
    private static func precedes(_ a: RecentPlay, _ b: RecentPlay) -> Bool {
        if a.isPlaying != b.isPlaying { return a.isPlaying }
        switch (a.playedAt, b.playedAt) {
        case (let x?, let y?): return x > y
        case (.some, nil): return true
        default: return false
        }
    }

    private static func isSamePlay(_ a: RecentPlay, _ b: RecentPlay) -> Bool {
        guard a.isSameSong(as: b) else { return false }
        if a.isPlaying && b.isPlaying { return true }
        guard let x = a.playedAt, let y = b.playedAt else { return true }
        return abs(x.timeIntervalSince(y)) <= samePlayWindow
    }

    /// `kept`, with details only `other` knows.
    private static func filling(_ kept: RecentPlay, from other: RecentPlay) -> RecentPlay {
        var play = kept
        play.album = play.album ?? other.album
        play.durationMs = play.durationMs ?? other.durationMs
        play.isrc = play.isrc ?? other.isrc
        play.mbid = play.mbid ?? other.mbid
        play.appleMusicId = play.appleMusicId ?? other.appleMusicId
        play.spotifyId = play.spotifyId ?? other.spotifyId
        play.youtubeId = play.youtubeId ?? other.youtubeId
        play.url = play.url ?? other.url
        play.artworkURL = play.artworkURL ?? other.artworkURL
        play.appName = play.appName ?? other.appName
        return play
    }
}
