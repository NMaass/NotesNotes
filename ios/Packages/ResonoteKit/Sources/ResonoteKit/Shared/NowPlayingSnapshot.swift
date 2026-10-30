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

    /// The Last.fm username: the linked account's, or one typed before web auth existed.
    public var lastfmUser: String?
    public var listenbrainzUser: String?
    public var appleMusicEnabled: Bool
    public var spotifyConnected: Bool
    /// The server holds a Last.fm session from web auth, so `GET /api/now-playing`
    /// reads Last.fm without a `lastfm` parameter.
    public var lastfmLinked: Bool
    /// A username typed before web auth, set aside while a linked account replaces it
    /// in `lastfmUser`; unlinking (or signing out) puts it back.
    public var lastfmTypedUser: String?

    public init(lastfmUser: String? = nil, listenbrainzUser: String? = nil, appleMusicEnabled: Bool = false, spotifyConnected: Bool = false, lastfmLinked: Bool = false, lastfmTypedUser: String? = nil) {
        self.lastfmUser = lastfmUser
        self.listenbrainzUser = listenbrainzUser
        self.appleMusicEnabled = appleMusicEnabled
        self.spotifyConnected = spotifyConnected
        self.lastfmLinked = lastfmLinked
        self.lastfmTypedUser = lastfmTypedUser
    }

    private enum CodingKeys: String, CodingKey { case lastfmUser, listenbrainzUser, appleMusicEnabled, spotifyConnected, lastfmLinked, lastfmTypedUser }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastfmUser = try c.decodeIfPresent(String.self, forKey: .lastfmUser)
        listenbrainzUser = try c.decodeIfPresent(String.self, forKey: .listenbrainzUser)
        appleMusicEnabled = try c.decodeIfPresent(Bool.self, forKey: .appleMusicEnabled) ?? false
        spotifyConnected = try c.decodeIfPresent(Bool.self, forKey: .spotifyConnected) ?? false
        lastfmLinked = try c.decodeIfPresent(Bool.self, forKey: .lastfmLinked) ?? false
        lastfmTypedUser = try c.decodeIfPresent(String.self, forKey: .lastfmTypedUser)
    }

    /// The Last.fm link changed: a linked account's username stands in for a typed one
    /// while it lasts, and the typed one comes back when it ends.
    public func withLastfmLink(_ linked: Bool, username: String?) -> LinkedSources {
        var sources = self
        if linked {
            if !lastfmLinked { sources.lastfmTypedUser = lastfmUser }
            sources.lastfmUser = username
        } else if lastfmLinked {
            sources.lastfmUser = lastfmTypedUser
            sources.lastfmTypedUser = nil
        }
        sources.lastfmLinked = linked
        return sources
    }

    public var hasRemote: Bool {
        lastfmLinked || !(lastfmUser ?? "").isEmpty || !(listenbrainzUser ?? "").isEmpty
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
