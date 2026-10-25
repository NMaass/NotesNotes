import Foundation

/// Every catalog row this device has seen, by id, so references, likes, and
/// collection items render without another request. Mirrors the web's selectors
/// (`getEntity`, `subtitleForEntity`) for subtitles and artwork.
///
/// `absorb` reports whether anything changed, and `adds` answers that without
/// mutating, so observers are told (and the cache file rewritten) only when a row is
/// new or different.
///
/// The index grows for the whole session; the copy kept on disk is bounded with
/// `pruned(keeping:limit:)`, so launch time and cache writes don't grow with months of use.
public struct CatalogIndex: Sendable, Hashable, Codable {
    public private(set) var artists: [String: Artist] = [:]
    public private(set) var albums: [String: Album] = [:]
    public private(set) var songs: [String: Song] = [:]
    public private(set) var genres: [String: Genre] = [:]
    /// Each artist's fallback cover: the first album cover URL in sorted order. Derived, not stored.
    private var artistCovers: [String: String] = [:]
    /// When each artist, album, and song was last added or changed (a counter), so pruning
    /// keeps the most recently seen rows. Not part of equality.
    private var stamps: [String: Int] = [:]
    private var clock = 0

    public init() {}

    private enum CodingKeys: String, CodingKey { case artists, albums, songs, genres, stamps }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artists = try c.decodeIfPresent([String: Artist].self, forKey: .artists) ?? [:]
        albums = try c.decodeIfPresent([String: Album].self, forKey: .albums) ?? [:]
        songs = try c.decodeIfPresent([String: Song].self, forKey: .songs) ?? [:]
        genres = try c.decodeIfPresent([String: Genre].self, forKey: .genres) ?? [:]
        stamps = (try? c.decodeIfPresent([String: Int].self, forKey: .stamps)) ?? [:]
        clock = stamps.values.max() ?? 0
        for album in albums.values { noteCover(of: album) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(artists, forKey: .artists)
        try c.encode(albums, forKey: .albums)
        try c.encode(songs, forKey: .songs)
        try c.encode(genres, forKey: .genres)
        try c.encode(stamps, forKey: .stamps)
    }

    public static func == (lhs: CatalogIndex, rhs: CatalogIndex) -> Bool {
        lhs.artists == rhs.artists && lhs.albums == rhs.albums && lhs.songs == rhs.songs && lhs.genres == rhs.genres
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(artists)
        hasher.combine(albums)
        hasher.combine(songs)
        hasher.combine(genres)
    }

    public var count: Int { artists.count + albums.count + songs.count + genres.count }

    // MARK: Bounding

    /// A copy that keeps every row in `kept` (the person's own journal: entries, likes,
    /// listens, collections, pins, genre tags), the `limit` most recently seen other
    /// artists, albums, and songs, the albums and artists those rows need to render, and
    /// every genre (there are few, and chips need their names).
    public func pruned(keeping kept: Set<String>, limit: Int) -> CatalogIndex {
        guard artists.count + albums.count + songs.count > kept.count + limit else { return self }
        // Rows from a cache written before stamps existed count as the oldest.
        let others = [Array(artists.keys), Array(albums.keys), Array(songs.keys)].joined().filter { !kept.contains($0) }
        let recent = others
            .map { ($0, stamps[$0] ?? 0) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(limit)
            .map(\.0)
        var keep = kept.union(recent)
        // What kept rows need: a song's album and artist, an album's artist.
        for id in Array(keep) {
            if let song = songs[id] {
                keep.insert(song.artistId)
                if let albumId = song.albumId { keep.insert(albumId) }
            }
        }
        for id in Array(keep) {
            if let album = albums[id] { keep.insert(album.artistId) }
        }
        var pruned = CatalogIndex()
        pruned.genres = genres
        pruned.artists = artists.filter { keep.contains($0.key) }
        pruned.albums = albums.filter { keep.contains($0.key) }
        pruned.songs = songs.filter { keep.contains($0.key) }
        pruned.stamps = stamps.filter { keep.contains($0.key) }
        pruned.clock = clock
        for album in pruned.albums.values { pruned.noteCover(of: album) }
        return pruned
    }

    private mutating func stamp(_ id: String) {
        clock += 1
        stamps[id] = clock
    }

    // MARK: Absorbing

    /// Whether absorbing `slice` would add or change a row.
    public func adds(_ slice: CatalogSlice) -> Bool {
        slice.artists.contains { artists[$0.id] != $0 }
            || slice.albums.contains { albums[$0.id] != $0 }
            || slice.songs.contains { songs[$0.id] != $0 }
            || slice.genres.contains { genres[$0.id] != $0 }
    }

    public func adds(_ entity: CatalogEntity) -> Bool {
        switch entity {
        case .artist(let artist): artists[artist.id] != artist
        case .album(let album): albums[album.id] != album
        case .song(let song): songs[song.id] != song
        case .genre(let genre): genres[genre.id] != genre
        }
    }

    public func adds(_ detail: EntityDetail) -> Bool {
        adds(detail.entity)
            || detail.artist.map { artists[$0.id] != $0 } ?? false
            || detail.album.map { albums[$0.id] != $0 } ?? false
            || detail.albums.contains { albums[$0.id] != $0 }
            || detail.tracks.contains { songs[$0.id] != $0 }
            || detail.genres.contains { genres[$0.genre.id] != $0.genre }
            || detail.connections.contains { adds($0.entity) }
            || adds(detail.catalog)
    }

    @discardableResult
    public mutating func absorb(_ slice: CatalogSlice) -> Bool {
        var changed = false
        for artist in slice.artists { changed = set(artist) || changed }
        for album in slice.albums { changed = set(album) || changed }
        for song in slice.songs { changed = set(song) || changed }
        for genre in slice.genres { changed = set(genre) || changed }
        return changed
    }

    @discardableResult
    public mutating func absorb(_ entity: CatalogEntity) -> Bool {
        switch entity {
        case .artist(let artist): set(artist)
        case .album(let album): set(album)
        case .song(let song): set(song)
        case .genre(let genre): set(genre)
        }
    }

    @discardableResult
    public mutating func absorb(_ entities: some Sequence<CatalogEntity>) -> Bool {
        var changed = false
        for entity in entities { changed = absorb(entity) || changed }
        return changed
    }

    @discardableResult
    public mutating func absorb(_ detail: EntityDetail) -> Bool {
        var changed = absorb(detail.entity)
        if let artist = detail.artist { changed = set(artist) || changed }
        if let album = detail.album { changed = set(album) || changed }
        for album in detail.albums { changed = set(album) || changed }
        for song in detail.tracks { changed = set(song) || changed }
        for tag in detail.genres { changed = set(tag.genre) || changed }
        for connection in detail.connections { changed = absorb(connection.entity) || changed }
        changed = absorb(detail.catalog) || changed
        return changed
    }

    /// Adds every row of `other`; its rows win where both have one.
    @discardableResult
    public mutating func absorb(_ other: CatalogIndex) -> Bool {
        absorb(CatalogSlice(artists: Array(other.artists.values), albums: Array(other.albums.values), songs: Array(other.songs.values), genres: Array(other.genres.values)))
    }

    private mutating func set(_ artist: Artist) -> Bool {
        guard artists[artist.id] != artist else { return false }
        artists[artist.id] = artist
        stamp(artist.id)
        return true
    }

    private mutating func set(_ album: Album) -> Bool {
        let previous = albums[album.id]
        guard previous != album else { return false }
        albums[album.id] = album
        stamp(album.id)
        if let previous, previous.imageUrl != nil, artistCovers[previous.artistId] == previous.imageUrl,
           previous.imageUrl != album.imageUrl || previous.artistId != album.artistId {
            // The cover this artist used changed: choose again among their albums.
            recomputeCover(for: previous.artistId)
        }
        noteCover(of: album)
        return true
    }

    private mutating func set(_ song: Song) -> Bool {
        guard songs[song.id] != song else { return false }
        songs[song.id] = song
        stamp(song.id)
        return true
    }

    private mutating func set(_ genre: Genre) -> Bool {
        guard genres[genre.id] != genre else { return false }
        genres[genre.id] = genre
        return true
    }

    private mutating func noteCover(of album: Album) {
        guard let url = album.imageUrl, !url.isEmpty else { return }
        if let current = artistCovers[album.artistId], current <= url { return }
        artistCovers[album.artistId] = url
    }

    private mutating func recomputeCover(for artistId: String) {
        artistCovers[artistId] = albums.values
            .filter { $0.artistId == artistId }
            .compactMap(\.imageUrl)
            .filter { !$0.isEmpty }
            .min()
    }

    // MARK: Reading

    public func entity(kind: EntityKind, id: String) -> CatalogEntity? {
        switch kind {
        case .artist: artists[id].map(CatalogEntity.artist)
        case .album: albums[id].map(CatalogEntity.album)
        case .song: songs[id].map(CatalogEntity.song)
        case .genre: genres[id].map(CatalogEntity.genre)
        }
    }

    public func entity(id: String) -> CatalogEntity? {
        if let song = songs[id] { return .song(song) }
        if let album = albums[id] { return .album(album) }
        if let artist = artists[id] { return .artist(artist) }
        if let genre = genres[id] { return .genre(genre) }
        return nil
    }

    /// "Country · Artist" | "Artist · 1991" | "Artist · Album" | "Genre"
    public func subtitle(for entity: CatalogEntity) -> String {
        switch entity {
        case .artist(let artist):
            return [artist.country, "Artist"].compactMap { $0 }.joined(separator: " · ")
        case .album(let album):
            return [artists[album.artistId]?.name, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        case .song(let song):
            return [artists[song.artistId]?.name, song.albumId.flatMap { albums[$0]?.name }].compactMap { $0 }.joined(separator: " · ")
        case .genre:
            return "Genre"
        }
    }

    /// The best image for an entity: its own, else its album's cover (an artist's first album cover).
    public func artworkURL(for entity: CatalogEntity) -> String? {
        if let own = entity.imageUrl { return own }
        switch entity {
        case .song(let song): return song.albumId.flatMap { albums[$0]?.imageUrl }
        case .artist(let artist): return artistCovers[artist.id]
        default: return nil
        }
    }

    public func artist(for entity: CatalogEntity) -> Artist? {
        entity.artistId.flatMap { artists[$0] }
    }

    public func album(for song: Song) -> Album? {
        song.albumId.flatMap { albums[$0] }
    }
}
