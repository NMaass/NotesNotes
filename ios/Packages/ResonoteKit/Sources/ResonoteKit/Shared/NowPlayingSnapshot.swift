import Foundation

/// What the widget, controls, and share extension know about "now", written by
/// whichever process learned something new last. Small by design: it is decoded on
/// every widget timeline request.
public struct NowPlayingSnapshot: Codable, Sendable, Hashable {
    public static let fileName = "now-playing.json"

    public var track: NowPlayingTrack?
    /// The catalog match and suggestions for `track`, when resolved.
    public var resolution: ResolveResponse?
    public var signedIn: Bool
    public var handle: String?
    /// Lenses and moods this person reaches for most, used when there is no resolution yet.
    public var habits: TagSuggestions?
    /// Song ids written about recently, so the widget can say "you wrote about this".
    public var recentlyNotedSongIds: [String]
    public var updatedAt: String

    public init(track: NowPlayingTrack? = nil, resolution: ResolveResponse? = nil, signedIn: Bool = false, handle: String? = nil, habits: TagSuggestions? = nil, recentlyNotedSongIds: [String] = [], updatedAt: String = ResonoteDate.now()) {
        self.track = track
        self.resolution = resolution
        self.signedIn = signedIn
        self.handle = handle
        self.habits = habits
        self.recentlyNotedSongIds = recentlyNotedSongIds
        self.updatedAt = updatedAt
    }

    public static func load() -> NowPlayingSnapshot {
        SharedFile.read(NowPlayingSnapshot.self, from: fileName) ?? NowPlayingSnapshot()
    }

    public func save() {
        SharedFile.write(self, to: Self.fileName)
    }

    /// The resolution only if it belongs to the current track.
    public var currentResolution: ResolveResponse? {
        guard let track, let resolution, resolution.track?.identity == track.identity else { return nil }
        return resolution
    }

    /// Suggestions to show right now: the song's own, else the person's habits, else defaults.
    public var suggestions: TagSuggestions {
        currentResolution?.suggestions ?? habits ?? TagSuggestions(lenses: [.feeling, .production, .context], moods: Array(Vocabulary.moods.prefix(3)))
    }
}

/// Settings for remote now-playing sources, shared so the widget can poll them too.
public struct LinkedSources: Codable, Sendable, Hashable {
    public static let defaultsKey = "linked-sources"

    public var lastfmUser: String?
    public var listenbrainzUser: String?
    public var appleMusicEnabled: Bool
    public var spotifyConnected: Bool

    public init(lastfmUser: String? = nil, listenbrainzUser: String? = nil, appleMusicEnabled: Bool = false, spotifyConnected: Bool = false) {
        self.lastfmUser = lastfmUser
        self.listenbrainzUser = listenbrainzUser
        self.appleMusicEnabled = appleMusicEnabled
        self.spotifyConnected = spotifyConnected
    }

    public var hasRemote: Bool {
        !(lastfmUser ?? "").isEmpty || !(listenbrainzUser ?? "").isEmpty
    }

    public static func load() -> LinkedSources {
        guard let data = AppGroup.defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(LinkedSources.self, from: data) else { return LinkedSources() }
        return value
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppGroup.defaults.set(data, forKey: Self.defaultsKey)
    }
}
