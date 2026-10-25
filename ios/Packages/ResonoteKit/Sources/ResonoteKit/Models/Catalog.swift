import Foundation

// Catalog entities mirror src/lib/data/types.ts. Every struct encodes its `kind`
// so payloads round-trip through the web app's discriminated union unchanged.

public struct Artist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: EntityKind { .artist }
    public var name: String
    public var slug: String
    public var imageUrl: String?
    public var musicbrainzId: String?
    public var summary: String?
    public var sortName: String?
    public var country: String?

    public init(id: String, name: String, slug: String, imageUrl: String? = nil, musicbrainzId: String? = nil, summary: String? = nil, sortName: String? = nil, country: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.imageUrl = imageUrl
        self.musicbrainzId = musicbrainzId
        self.summary = summary
        self.sortName = sortName
        self.country = country
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, slug, imageUrl, musicbrainzId, summary, sortName, country }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        musicbrainzId = try c.decodeIfPresent(String.self, forKey: .musicbrainzId)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        sortName = try c.decodeIfPresent(String.self, forKey: .sortName)
        country = try c.decodeIfPresent(String.self, forKey: .country)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(slug, forKey: .slug)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encodeIfPresent(musicbrainzId, forKey: .musicbrainzId)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(sortName, forKey: .sortName)
        try c.encodeIfPresent(country, forKey: .country)
    }
}

public struct Album: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: EntityKind { .album }
    public var name: String
    public var slug: String
    public var imageUrl: String?
    public var musicbrainzId: String?
    public var summary: String?
    public var artistId: String
    public var year: Int?
    public var releaseGroupType: String?

    public init(id: String, name: String, slug: String, artistId: String, imageUrl: String? = nil, musicbrainzId: String? = nil, summary: String? = nil, year: Int? = nil, releaseGroupType: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.artistId = artistId
        self.imageUrl = imageUrl
        self.musicbrainzId = musicbrainzId
        self.summary = summary
        self.year = year
        self.releaseGroupType = releaseGroupType
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, slug, imageUrl, musicbrainzId, summary, artistId, year, releaseGroupType }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        musicbrainzId = try c.decodeIfPresent(String.self, forKey: .musicbrainzId)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId) ?? ""
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        releaseGroupType = try c.decodeIfPresent(String.self, forKey: .releaseGroupType)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(slug, forKey: .slug)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encodeIfPresent(musicbrainzId, forKey: .musicbrainzId)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(artistId, forKey: .artistId)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(releaseGroupType, forKey: .releaseGroupType)
    }
}

public struct Song: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: EntityKind { .song }
    public var name: String
    public var slug: String
    public var imageUrl: String?
    public var musicbrainzId: String?
    public var summary: String?
    public var artistId: String
    public var albumId: String?
    public var trackNumber: Int?
    public var durationMs: Int?
    public var spotifyId: String?
    public var youtubeId: String?
    public var isBonusTrack: Bool?

    public init(id: String, name: String, slug: String, artistId: String, albumId: String? = nil, imageUrl: String? = nil, musicbrainzId: String? = nil, summary: String? = nil, trackNumber: Int? = nil, durationMs: Int? = nil, spotifyId: String? = nil, youtubeId: String? = nil, isBonusTrack: Bool? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.artistId = artistId
        self.albumId = albumId
        self.imageUrl = imageUrl
        self.musicbrainzId = musicbrainzId
        self.summary = summary
        self.trackNumber = trackNumber
        self.durationMs = durationMs
        self.spotifyId = spotifyId
        self.youtubeId = youtubeId
        self.isBonusTrack = isBonusTrack
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, slug, imageUrl, musicbrainzId, summary, artistId, albumId, trackNumber, durationMs, spotifyId, youtubeId, isBonusTrack }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        musicbrainzId = try c.decodeIfPresent(String.self, forKey: .musicbrainzId)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId) ?? ""
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        spotifyId = try c.decodeIfPresent(String.self, forKey: .spotifyId)
        youtubeId = try c.decodeIfPresent(String.self, forKey: .youtubeId)
        isBonusTrack = try c.decodeIfPresent(Bool.self, forKey: .isBonusTrack)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(slug, forKey: .slug)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encodeIfPresent(musicbrainzId, forKey: .musicbrainzId)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encode(artistId, forKey: .artistId)
        try c.encodeIfPresent(albumId, forKey: .albumId)
        try c.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encodeIfPresent(spotifyId, forKey: .spotifyId)
        try c.encodeIfPresent(youtubeId, forKey: .youtubeId)
        try c.encodeIfPresent(isBonusTrack, forKey: .isBonusTrack)
    }
}

public struct Genre: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: EntityKind { .genre }
    public var name: String
    public var slug: String
    public var imageUrl: String?
    public var musicbrainzId: String?
    public var summary: String?
    public var description: String?

    public init(id: String, name: String, slug: String, imageUrl: String? = nil, musicbrainzId: String? = nil, summary: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.imageUrl = imageUrl
        self.musicbrainzId = musicbrainzId
        self.summary = summary
        self.description = description
    }

    private enum CodingKeys: String, CodingKey { case id, kind, name, slug, imageUrl, musicbrainzId, summary, description }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        musicbrainzId = try c.decodeIfPresent(String.self, forKey: .musicbrainzId)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(slug, forKey: .slug)
        try c.encodeIfPresent(imageUrl, forKey: .imageUrl)
        try c.encodeIfPresent(musicbrainzId, forKey: .musicbrainzId)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

/// The discriminated union `CatalogEntity` from the web app, keyed by `kind`.
public enum CatalogEntity: Codable, Sendable, Hashable, Identifiable {
    case artist(Artist)
    case album(Album)
    case song(Song)
    case genre(Genre)

    public var id: String {
        switch self {
        case .artist(let value): value.id
        case .album(let value): value.id
        case .song(let value): value.id
        case .genre(let value): value.id
        }
    }

    public var kind: EntityKind {
        switch self {
        case .artist: .artist
        case .album: .album
        case .song: .song
        case .genre: .genre
        }
    }

    public var name: String {
        switch self {
        case .artist(let value): value.name
        case .album(let value): value.name
        case .song(let value): value.name
        case .genre(let value): value.name
        }
    }

    public var slug: String {
        switch self {
        case .artist(let value): value.slug
        case .album(let value): value.slug
        case .song(let value): value.slug
        case .genre(let value): value.slug
        }
    }

    public var imageUrl: String? {
        switch self {
        case .artist(let value): value.imageUrl
        case .album(let value): value.imageUrl
        case .song(let value): value.imageUrl
        case .genre(let value): value.imageUrl
        }
    }

    public var summary: String? {
        switch self {
        case .artist(let value): value.summary
        case .album(let value): value.summary
        case .song(let value): value.summary
        case .genre(let value): value.description ?? value.summary
        }
    }

    public var musicbrainzId: String? {
        switch self {
        case .artist(let value): value.musicbrainzId
        case .album(let value): value.musicbrainzId
        case .song(let value): value.musicbrainzId
        case .genre(let value): value.musicbrainzId
        }
    }

    /// The artist id for albums and songs; the entity's own id for artists.
    public var artistId: String? {
        switch self {
        case .artist(let value): value.id
        case .album(let value): value.artistId
        case .song(let value): value.artistId
        case .genre: nil
        }
    }

    private enum KindKey: String, CodingKey { case kind }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: KindKey.self)
        let kind = try container.decode(EntityKind.self, forKey: .kind)
        switch kind {
        case .artist: self = .artist(try Artist(from: decoder))
        case .album: self = .album(try Album(from: decoder))
        case .song: self = .song(try Song(from: decoder))
        case .genre: self = .genre(try Genre(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .artist(let value): try value.encode(to: encoder)
        case .album(let value): try value.encode(to: encoder)
        case .song(let value): try value.encode(to: encoder)
        case .genre(let value): try value.encode(to: encoder)
        }
    }
}

/// Catalog rows that live only in D1 (imports), shipped alongside bundles so
/// clients can render references without another round trip.
public struct CatalogSlice: Codable, Sendable, Hashable {
    public var artists: [Artist]
    public var albums: [Album]
    public var songs: [Song]
    public var genres: [Genre]

    public init(artists: [Artist] = [], albums: [Album] = [], songs: [Song] = [], genres: [Genre] = []) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
        self.genres = genres
    }

    private enum CodingKeys: String, CodingKey { case artists, albums, songs, genres }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artists = try c.decodeLossyArray(Artist.self, forKey: .artists)
        albums = try c.decodeLossyArray(Album.self, forKey: .albums)
        songs = try c.decodeLossyArray(Song.self, forKey: .songs)
        genres = try c.decodeLossyArray(Genre.self, forKey: .genres)
    }

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty && genres.isEmpty }
}

public struct EntityGenre: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable { case catalog, community, user, musicbrainz }

    public var id: String?
    public var entityId: String
    public var entityKind: EntityKind?
    public var genreId: String
    public var source: Source
    public var createdBy: String?
    public var votes: Int?

    public init(id: String? = nil, entityId: String, entityKind: EntityKind?, genreId: String, source: Source, createdBy: String? = nil, votes: Int? = nil) {
        self.id = id
        self.entityId = entityId
        self.entityKind = entityKind
        self.genreId = genreId
        self.source = source
        self.createdBy = createdBy
        self.votes = votes
    }
}

public struct SongCredit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var songId: String
    public var name: String
    public var role: String
    public var collaboratorKey: String
    public var artistId: String?
    public var sourceLabel: String
    public var sourceUrl: String?
}

public struct SongFact: Codable, Sendable, Hashable, Identifiable {
    public enum Confidence: String, Codable, Sendable { case catalog, estimated, community }

    public var id: String
    public var songId: String
    public var label: String
    public var value: String
    public var sourceLabel: String
    public var sourceUrl: String?
    public var confidence: Confidence
}

public struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    public enum Source: String, Codable, Sendable { case local, musicbrainz }

    public var entity: CatalogEntity
    public var subtitle: String
    public var source: Source

    public var id: String { entity.id }

    public init(entity: CatalogEntity, subtitle: String, source: Source) {
        self.entity = entity
        self.subtitle = subtitle
        self.source = source
    }
}
