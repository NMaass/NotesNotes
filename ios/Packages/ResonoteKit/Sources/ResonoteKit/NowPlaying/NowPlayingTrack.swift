import Foundation

/// A track some source says the person is (or was just) listening to, before it is
/// matched to a Resonote catalog song. Every source normalizes into this one shape,
/// and the backend's `/api/music/resolve` and `/api/now-playing` speak it too.
public struct NowPlayingTrack: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case appleMusic = "apple-music"
        case spotify
        case lastfm
        case listenbrainz
        case shazam
        case link
        case manual

        public var label: String {
            switch self {
            case .appleMusic: "Apple Music"
            case .spotify: "Spotify"
            case .lastfm: "Last.fm"
            case .listenbrainz: "ListenBrainz"
            case .shazam: "Shazam"
            case .link: "Shared link"
            case .manual: "Search"
            }
        }
    }

    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int?
    public var artworkURL: String?
    /// International Standard Recording Code; the most reliable cross-service key.
    public var isrc: String?
    /// MusicBrainz recording id, when the source already knows it (ListenBrainz does).
    public var mbid: String?
    public var spotifyId: String?
    public var appleMusicId: String?
    public var youtubeId: String?
    /// A link that opens this track in its provider.
    public var url: String?
    public var source: Source
    /// `true` while the source reports active playback; `false` for "last played".
    public var isPlaying: Bool
    /// ISO-8601 time the source reported this track.
    public var observedAt: String

    public init(title: String, artist: String, album: String? = nil, durationMs: Int? = nil, artworkURL: String? = nil, isrc: String? = nil, mbid: String? = nil, spotifyId: String? = nil, appleMusicId: String? = nil, youtubeId: String? = nil, url: String? = nil, source: Source, isPlaying: Bool, observedAt: String = ResonoteDate.now()) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.isrc = isrc
        self.mbid = mbid
        self.spotifyId = spotifyId
        self.appleMusicId = appleMusicId
        self.youtubeId = youtubeId
        self.url = url
        self.source = source
        self.isPlaying = isPlaying
        self.observedAt = observedAt
    }

    /// Stable identity for "is this the same song as before?" checks across sources.
    public var identity: String {
        if let isrc, !isrc.isEmpty { return "isrc:\(isrc.uppercased())" }
        return "text:\(TrackText.matchKey(artist: artist, title: title))"
    }

    public var observedDate: Date? { ResonoteDate.parse(observedAt) }
}

extension NowPlayingTrack.Source {
    /// Sources that report playback as it happens, as opposed to a one-time match or a pick.
    public var isLive: Bool {
        switch self {
        case .appleMusic, .spotify, .lastfm, .listenbrainz: true
        case .shazam, .link, .manual: false
        }
    }
}

extension NowPlayingTrack {
    /// How long a live source's "playing" stays believable without a fresh sample.
    public static let livePlayingWindow: TimeInterval = 10 * 60
    /// How long a one-time report (a Shazam match, a Shortcut) may say "playing" when the song's length is unknown.
    public static let assumedSongLength: TimeInterval = 4 * 60
    /// Older than this, a song is history rather than "now".
    public static let staleAfter: TimeInterval = 12 * 60 * 60

    /// When this report stops vouching for playback, or nil when it never did. A live
    /// source vouches for its sampling window; a one-time report for about one song.
    public var playbackClaimEnds: Date? {
        guard isPlaying, let observed = observedDate else { return nil }
        if source.isLive { return observed.addingTimeInterval(Self.livePlayingWindow) }
        let length = durationMs.map { TimeInterval($0) / 1000 } ?? Self.assumedSongLength
        return observed.addingTimeInterval(min(max(length, 30), Self.livePlayingWindow))
    }

    /// Whether the interface may say this track is playing at `date`: the one rule the
    /// app, the widget, and the accessory share.
    public func claimsPlayback(at date: Date = Date()) -> Bool {
        guard let end = playbackClaimEnds else { return false }
        return date < end
    }

    /// Whether this report is too old to present as "now".
    public func isStale(at date: Date = Date()) -> Bool {
        guard let observed = observedDate else { return false }
        return date.timeIntervalSince(observed) > Self.staleAfter
    }
}
