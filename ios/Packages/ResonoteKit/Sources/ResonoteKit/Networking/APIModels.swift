import Foundation

// Request and response shapes for the Resonote backend. Endpoints marked "new"
// were added for native clients; see docs/IOS_API.md for the full contract.

public struct RequestCodeResponse: Decodable, Sendable {
    public var ok: Bool
    /// Present only when the server has no mail provider (local development).
    public var devCode: String?
    public var error: String?
}

public struct VerifyResponse: Decodable, Sendable {
    public var ok: Bool
    public var bundle: ProfileBundle?
    /// Bearer token for native clients (sent when the request says `client: "ios"`).
    public var token: String?
    public var expiresAt: String?
    public var error: String?
}

public struct SessionResponse: Decodable, Sendable {
    public var authenticated: Bool
    public var bundle: ProfileBundle?
}

public struct PublicProfileResponse: Decodable, Sendable {
    public var ok: Bool
    public var bundle: ProfileBundle?
    public var error: String?
}

public struct SearchResponse: Decodable, Sendable {
    public var results: [SearchResult]

    private enum CodingKeys: String, CodingKey { case results }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeLossyArray(SearchResult.self, forKey: .results)
    }
}

public struct ImportResponse: Decodable, Sendable {
    public var ok: Bool
    public var bundle: CatalogSlice?
    public var error: String?
}

public struct GenresResponse: Decodable, Sendable {
    public var genres: [Genre]
}

/// A genre and how strongly it is attached to an entity, combining catalog and listener tags.
public struct GenreTagCount: Codable, Sendable, Hashable, Identifiable {
    public var genre: Genre
    public var source: EntityGenre.Source
    public var votes: Int
    /// Whether the signed-in person has asserted this genre themselves.
    public var mine: Bool?

    public var id: String { genre.id }
}

/// A music-to-music link that writers made explicitly in their entries.
public struct Connection: Codable, Sendable, Hashable, Identifiable {
    public var entity: CatalogEntity
    public var count: Int
    public var lenses: [MusicLens]
    public var relations: [RelationKind]

    public var id: String { entity.id }
}

/// new: `GET /api/catalog/entity?kind=&id=` — everything one entity screen needs in one round trip.
public struct EntityDetail: Decodable, Sendable {
    public var entity: CatalogEntity
    public var artist: Artist?
    public var album: Album?
    /// Albums by the artist (artist pages) or sibling releases.
    public var albums: [Album]
    /// The album tracklist, the artist's songs, or a genre's songs.
    public var tracks: [Song]
    public var genres: [GenreTagCount]
    public var credits: [SongCredit]
    public var facts: [SongFact]
    /// Public entries about this entity, newest first.
    public var entries: [JournalEntry]
    public var authors: [Profile]
    public var connections: [Connection]
    /// Catalog rows referenced by `entries` that a client may not have.
    public var catalog: CatalogSlice
    /// Genre pages: how many times anyone tagged this genre (the web's `getGenreTagCount`).
    /// Optional so older servers that leave it out still decode.
    public var tagCount: Int?

    private enum CodingKeys: String, CodingKey { case entity, artist, album, albums, tracks, genres, credits, facts, entries, authors, connections, catalog, tagCount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entity = try c.decode(CatalogEntity.self, forKey: .entity)
        artist = try c.decodeIfPresent(Artist.self, forKey: .artist)
        album = try c.decodeIfPresent(Album.self, forKey: .album)
        albums = try c.decodeLossyArray(Album.self, forKey: .albums)
        tracks = try c.decodeLossyArray(Song.self, forKey: .tracks)
        genres = try c.decodeLossyArray(GenreTagCount.self, forKey: .genres)
        credits = try c.decodeLossyArray(SongCredit.self, forKey: .credits)
        facts = try c.decodeLossyArray(SongFact.self, forKey: .facts)
        entries = try c.decodeLossyArray(JournalEntry.self, forKey: .entries)
        authors = try c.decodeLossyArray(Profile.self, forKey: .authors)
        connections = try c.decodeLossyArray(Connection.self, forKey: .connections)
        catalog = try c.decodeIfPresent(CatalogSlice.self, forKey: .catalog) ?? CatalogSlice()
        tagCount = try? c.decodeIfPresent(Int.self, forKey: .tagCount)
    }
}

/// new: `GET /api/feed?limit=&before=` — recent public entries across everyone.
public struct FeedResponse: Decodable, Sendable {
    public var entries: [JournalEntry]
    public var profiles: [Profile]
    public var catalog: CatalogSlice
    /// Pass back as `before` to load the next page; nil when there is no more.
    public var nextCursor: String?

    private enum CodingKeys: String, CodingKey { case entries, profiles, catalog, nextCursor }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeLossyArray(JournalEntry.self, forKey: .entries)
        profiles = try c.decodeLossyArray(Profile.self, forKey: .profiles)
        catalog = try c.decodeIfPresent(CatalogSlice.self, forKey: .catalog) ?? CatalogSlice()
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// A suggested genre tag for a resolved song. `id` is assertable through the
/// `genre-assertion` sync op.
public struct GenreSuggestion: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Where the suggestion came from: the seeded catalog, MusicBrainz community tags, or listeners on Resonote.
    public var source: String

    public init(id: String, name: String, source: String) {
        self.id = id
        self.name = name
        self.source = source
    }
}

/// What to offer when someone is about to write about a song.
public struct TagSuggestions: Codable, Sendable, Hashable {
    public var genres: [GenreSuggestion]
    public var lenses: [MusicLens]
    public var moods: [String]
    public var prompt: String

    public init(genres: [GenreSuggestion] = [], lenses: [MusicLens] = [], moods: [String] = [], prompt: String = Vocabulary.prompts[1]) {
        self.genres = genres
        self.lenses = lenses
        self.moods = moods
        self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey { case genres, lenses, moods, prompt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = try c.decodeLossyArray(GenreSuggestion.self, forKey: .genres)
        lenses = try c.decodeLossyArray(MusicLens.self, forKey: .lenses)
        moods = try c.decodeIfPresent([String].self, forKey: .moods) ?? []
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? Vocabulary.prompts[1]
    }
}

/// new: `POST /api/music/resolve` request — either a track from a source or a shared link.
public struct ResolveRequest: Encodable, Sendable {
    public var track: NowPlayingTrack?
    public var url: String?

    public init(track: NowPlayingTrack) {
        self.track = track
        self.url = nil
    }

    public init(url: String) {
        self.track = nil
        self.url = url
    }
}

/// new: the catalog song a now-playing track maps to, imported on demand, plus suggestions.
public struct ResolveResponse: Codable, Sendable, Hashable {
    public enum Confidence: String, Codable, Sendable {
        /// Matched by MusicBrainz id or ISRC.
        case exact
        /// Matched by normalized artist and title (and duration when known).
        case strong
        /// Best search guess; show it, but let the person correct it.
        case weak
        /// Nothing found.
        case none
    }

    public var track: NowPlayingTrack?
    public var song: Song?
    public var album: Album?
    public var artist: Artist?
    public var confidence: Confidence
    /// For `weak`/`none`: MusicBrainz recordings to offer instead. Not imported until chosen.
    public var candidates: [SearchResult]
    public var suggestions: TagSuggestions
    /// Public entries already written about the matched song.
    public var entriesCount: Int

    public init(track: NowPlayingTrack?, song: Song?, album: Album?, artist: Artist?, confidence: Confidence, candidates: [SearchResult] = [], suggestions: TagSuggestions, entriesCount: Int) {
        self.track = track
        self.song = song
        self.album = album
        self.artist = artist
        self.confidence = confidence
        self.candidates = candidates
        self.suggestions = suggestions
        self.entriesCount = entriesCount
    }

    private enum CodingKeys: String, CodingKey { case track, song, album, artist, confidence, candidates, suggestions, entriesCount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decodeIfPresent(NowPlayingTrack.self, forKey: .track)
        song = try c.decodeIfPresent(Song.self, forKey: .song)
        album = try c.decodeIfPresent(Album.self, forKey: .album)
        artist = try c.decodeIfPresent(Artist.self, forKey: .artist)
        confidence = (try? c.decode(Confidence.self, forKey: .confidence)) ?? .none
        candidates = try c.decodeLossyArray(SearchResult.self, forKey: .candidates)
        suggestions = try c.decodeIfPresent(TagSuggestions.self, forKey: .suggestions) ?? TagSuggestions()
        entriesCount = try c.decodeIfPresent(Int.self, forKey: .entriesCount) ?? 0
    }
}

/// new: `GET /api/now-playing?lastfm=&listenbrainz=&resolve=1` — the freshest
/// track across the person's linked scrobbling accounts, optionally resolved.
public struct RemoteNowPlayingResponse: Decodable, Sendable {
    public var track: NowPlayingTrack?
    public var resolution: ResolveResponse?
}

/// Writes accepted by `POST /api/sync`. The server trusts only the bearer token's
/// user; profile ids in payloads are ignored.
public enum SyncOperation: Sendable {
    case like(id: String, entityId: String, entityKind: EntityKind, clientVersion: Int, liked: Bool)
    case genreAssertion(entityId: String, entityKind: EntityKind, genreId: String, asserted: Bool)
    case entry(JournalEntry)
    case deleteEntry(id: String)
    case listen(ListenLog)
    case collection(MusicCollection)
    case deleteCollection(id: String)
    case pin(targetType: ProfilePin.TargetType, targetId: String, position: Int, pinned: Bool)
    case profile(displayName: String, bio: String, avatarUrl: String?, profileSongId: String?, genreIds: [String])

    /// Writes to the same object share a key so they serialize and the latest intent wins.
    public var queueKey: String {
        switch self {
        case .like(_, let entityId, _, _, _): "like:\(entityId)"
        case .genreAssertion(let entityId, _, let genreId, _): "genre:\(entityId):\(genreId)"
        case .entry(let entry): "entry:\(entry.id)"
        case .deleteEntry(let id): "entry:\(id)"
        case .listen(let listen): "listen:\(listen.id)"
        case .collection(let collection): "collection:\(collection.id)"
        case .deleteCollection(let id): "collection:\(id)"
        case .pin(let targetType, let targetId, _, _): "pin:\(targetType.rawValue):\(targetId)"
        case .profile: "profile"
        }
    }

    /// For a delete of an entry or collection: the unpin of the same target. The outbox
    /// queues it when a pin for that target is still waiting, so the pin can't be sent
    /// after the delete and leave a pin on something that no longer exists.
    public var unpinOnDelete: SyncOperation? {
        switch self {
        case .deleteEntry(let id): .pin(targetType: .entry, targetId: id, position: 0, pinned: false)
        case .deleteCollection(let id): .pin(targetType: .collection, targetId: id, position: 0, pinned: false)
        default: nil
        }
    }

    /// The `op` the server sees.
    public var opName: String {
        switch self {
        case .like: "like"
        case .genreAssertion: "genre-assertion"
        case .entry: "entry"
        case .deleteEntry: "delete-entry"
        case .listen: "listen"
        case .collection: "collection"
        case .deleteCollection: "delete-collection"
        case .pin: "pin"
        case .profile: "profile"
        }
    }
}

/// new: `GET /api/moderation/blocks` — the people this person has blocked.
public struct BlockedProfilesResponse: Decodable, Sendable {
    public var profiles: [Profile]

    private enum CodingKeys: String, CodingKey { case profiles }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeLossyArray(Profile.self, forKey: .profiles)
    }
}

/// What a report says is wrong with someone's writing or profile.
public enum ReportReason: String, Codable, Sendable, CaseIterable, Identifiable {
    case spam
    case harassment
    case hate
    case sexual
    case other

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .spam: "Spam or misleading"
        case .harassment: "Harassment or bullying"
        case .hate: "Hateful content"
        case .sexual: "Sexual content"
        case .other: "Something else"
        }
    }
}

/// new: `POST /api/moderation/reports`.
public struct ReportRequest: Encodable, Sendable {
    public enum TargetType: String, Encodable, Sendable { case entry, profile }

    public var targetType: TargetType
    public var targetId: String
    public var reason: ReportReason

    public init(targetType: TargetType, targetId: String, reason: ReportReason) {
        self.targetType = targetType
        self.targetId = targetId
        self.reason = reason
    }
}

extension SyncOperation: Encodable {
    private enum CodingKeys: String, CodingKey {
        case op, id, entityId, entityKind, clientVersion, liked, genreId, asserted, entry, listen, collection, targetType, targetId, position, pinned, profile
    }

    private struct ProfileFields: Encodable {
        var displayName: String
        var bio: String
        var avatarUrl: String?
        var profileSongId: String?
        var genreIds: [String]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .like(let id, let entityId, let entityKind, let clientVersion, let liked):
            try c.encode("like", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(entityId, forKey: .entityId)
            try c.encode(entityKind, forKey: .entityKind)
            try c.encode(clientVersion, forKey: .clientVersion)
            try c.encode(liked, forKey: .liked)
        case .genreAssertion(let entityId, let entityKind, let genreId, let asserted):
            try c.encode("genre-assertion", forKey: .op)
            try c.encode(entityId, forKey: .entityId)
            try c.encode(entityKind, forKey: .entityKind)
            try c.encode(genreId, forKey: .genreId)
            try c.encode(asserted, forKey: .asserted)
        case .entry(let entry):
            try c.encode("entry", forKey: .op)
            try c.encode(entry, forKey: .entry)
        case .deleteEntry(let id):
            try c.encode("delete-entry", forKey: .op)
            try c.encode(id, forKey: .id)
        case .listen(let listen):
            try c.encode("listen", forKey: .op)
            try c.encode(listen, forKey: .listen)
        case .collection(let collection):
            try c.encode("collection", forKey: .op)
            try c.encode(collection, forKey: .collection)
        case .deleteCollection(let id):
            try c.encode("delete-collection", forKey: .op)
            try c.encode(id, forKey: .id)
        case .pin(let targetType, let targetId, let position, let pinned):
            try c.encode("pin", forKey: .op)
            try c.encode(targetType, forKey: .targetType)
            try c.encode(targetId, forKey: .targetId)
            try c.encode(position, forKey: .position)
            try c.encode(pinned, forKey: .pinned)
        case .profile(let displayName, let bio, let avatarUrl, let profileSongId, let genreIds):
            try c.encode("profile", forKey: .op)
            try c.encode(ProfileFields(displayName: displayName, bio: bio, avatarUrl: avatarUrl, profileSongId: profileSongId, genreIds: genreIds), forKey: .profile)
        }
    }
}
