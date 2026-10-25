import Foundation
import ResonoteKit

/// Everything an entity screen shows, prepared once per load (off the main actor)
/// so view bodies only read values: sorted lists, duration strings, artwork choices.
nonisolated struct EntityPage: Sendable {
    nonisolated struct Track: Sendable, Identifiable {
        let song: Song
        let number: String
        let duration: String?
        var id: String { song.id }
    }

    nonisolated struct SongLine: Sendable, Identifiable {
        let song: Song
        let subtitle: String
        let artworkURL: String?
        var id: String { song.id }
    }

    nonisolated struct ConnectionLine: Sendable, Identifiable {
        let entity: CatalogEntity
        let artworkURL: String?
        let relations: String
        let lenses: [String]
        let mentions: String
        var id: String { entity.id }
    }

    let entity: CatalogEntity
    let artist: Artist?
    let album: Album?
    let artworkURL: String?
    /// Up to four covers for a genre's mosaic.
    let mosaic: [String]
    let duration: String?
    let summary: String?
    /// Album tracklist, by track number.
    let tracklist: [Track]
    /// An artist's albums, or the albums tagged with a genre.
    let albums: [Album]
    /// An artist's songs, or the songs tagged with a genre.
    let songs: [SongLine]
    let genres: [GenreTagCount]
    let credits: [SongCredit]
    let facts: [SongFact]
    let connections: [ConnectionLine]
    /// Public entries, newest first.
    let entries: [JournalEntry]
    let authors: [String: Profile]
    /// "12 records tagged so far" on genre pages.
    let taggedSummary: String?
    /// Whose `mine` flags the genre tags carry (the viewer when it loaded).
    let viewer: String?
    /// `false` while only the locally known entity is available.
    let isComplete: Bool

    var name: String { entity.name }
    var kind: EntityKind { entity.kind }

    /// A page drawn from what this device already knows, shown while the full page loads.
    init(seed entity: CatalogEntity, catalog: CatalogIndex) {
        self.entity = entity
        switch entity {
        case .song(let song):
            artist = catalog.artists[song.artistId]
            album = catalog.album(for: song)
            duration = Self.duration(song.durationMs)
        case .album(let album):
            artist = catalog.artists[album.artistId]
            self.album = nil
            duration = nil
        case .artist, .genre:
            artist = nil
            album = nil
            duration = nil
        }
        artworkURL = catalog.artworkURL(for: entity)
        mosaic = []
        summary = Self.headerSummary(entity)
        tracklist = []
        albums = []
        songs = []
        genres = []
        credits = []
        facts = []
        connections = []
        entries = []
        authors = [:]
        taggedSummary = nil
        viewer = nil
        isComplete = false
    }

    init(detail: EntityDetail, viewer: String?) {
        let entity = detail.entity
        self.entity = entity
        self.viewer = viewer
        isComplete = true
        artist = detail.artist
        album = detail.album

        var albumsById: [String: Album] = [:]
        for album in detail.catalog.albums { albumsById[album.id] = album }
        for album in detail.albums { albumsById[album.id] = album }
        if let album = detail.album { albumsById[album.id] = album }
        if case .album(let own) = entity { albumsById[own.id] = own }
        var artistsById: [String: Artist] = [:]
        for artist in detail.catalog.artists { artistsById[artist.id] = artist }
        if let artist = detail.artist { artistsById[artist.id] = artist }
        if case .artist(let own) = entity { artistsById[own.id] = own }

        func cover(of song: Song) -> String? {
            song.imageUrl ?? song.albumId.flatMap { albumsById[$0]?.imageUrl }
        }

        switch entity {
        case .song(let song):
            artworkURL = cover(of: song)
            duration = Self.duration(song.durationMs)
        case .album(let album):
            artworkURL = album.imageUrl
            duration = nil
        case .artist(let artist):
            artworkURL = artist.imageUrl ?? detail.albums.compactMap(\.imageUrl).sorted().first
            duration = nil
        case .genre(let genre):
            artworkURL = genre.imageUrl
            duration = nil
        }
        summary = Self.headerSummary(entity)

        if case .album = entity {
            tracklist = detail.tracks
                .sorted { ($0.trackNumber ?? 9_999, $0.name) < ($1.trackNumber ?? 9_999, $1.name) }
                .map { Track(song: $0, number: $0.trackNumber.map(String.init) ?? "–", duration: Self.duration($0.durationMs)) }
        } else {
            tracklist = []
        }

        switch entity {
        case .artist:
            albums = detail.albums.sorted { ($0.year ?? 9_999, $0.name) < ($1.year ?? 9_999, $1.name) }
            songs = detail.tracks.map { song in
                SongLine(song: song, subtitle: song.albumId.flatMap { albumsById[$0]?.name } ?? "", artworkURL: cover(of: song))
            }
        case .genre:
            albums = detail.albums
            songs = detail.tracks.map { song in
                let subtitle = [artistsById[song.artistId]?.name, song.albumId.flatMap { albumsById[$0]?.name }]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return SongLine(song: song, subtitle: subtitle, artworkURL: cover(of: song))
            }
        case .album, .song:
            albums = []
            songs = []
        }

        if case .genre = entity {
            var seen = Set<String>()
            let covers = detail.albums.compactMap(\.imageUrl) + detail.tracks.compactMap(cover(of:))
            mosaic = Array(covers.filter { seen.insert($0).inserted }.prefix(4))
            if let tagCount = detail.tagCount {
                // The server's total, worded as the web's genre page.
                switch tagCount {
                case 0: taggedSummary = "Nothing tagged yet — what genre do you think this is?"
                case 1: taggedSummary = "1 tag so far — what genre do you think this is?"
                default: taggedSummary = "\(tagCount) tags so far — what genre do you think this is?"
                }
            } else {
                // Older servers send no total: count the records listed (capped at 50 each).
                let count = detail.albums.count + detail.tracks.count
                let capped = detail.albums.count >= 50 || detail.tracks.count >= 50
                switch count {
                case 0: taggedSummary = "Nothing tagged yet — what genre do you think this is?"
                case 1: taggedSummary = "1 record tagged so far — what genre do you think this is?"
                default: taggedSummary = "\(count)\(capped ? "+" : "") records tagged so far — what genre do you think this is?"
                }
            }
        } else {
            mosaic = []
            taggedSummary = nil
        }

        genres = detail.genres
        credits = detail.credits
        facts = detail.facts
        connections = detail.connections.map { connection in
            let artwork: String? = switch connection.entity {
            case .song(let song): cover(of: song)
            case .artist(let artist): artist.imageUrl ?? albumsById.values.filter { $0.artistId == artist.id }.compactMap(\.imageUrl).sorted().first
            default: connection.entity.imageUrl
            }
            let relations = connection.relations.map(Self.connectionLabel).joined(separator: " · ")
            return ConnectionLine(
                entity: connection.entity,
                artworkURL: artwork,
                relations: relations,
                lenses: connection.lenses.map(\.rawValue),
                mentions: connection.count == 1 ? "1 mention" : "\(connection.count) mentions"
            )
        }
        entries = detail.entries
        authors = Dictionary(detail.authors.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The web player's `formatDuration`: rounded seconds as m:ss.
    static func duration(_ milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let seconds = Int((Double(milliseconds) / 1000).rounded())
        let remainder = seconds % 60
        return "\(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder)"
    }

    /// Genres keep their description for the page body; everyone else shows their summary up top.
    private static func headerSummary(_ entity: CatalogEntity) -> String? {
        let text: String? = switch entity {
        case .genre(let genre): genre.summary
        default: entity.summary
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// How the connections panel on the web phrases each relation.
    static func connectionLabel(_ relation: RelationKind) -> String {
        switch relation {
        case .remindsMeOf: "reminds listeners of"
        case .influencedBy: "heard as an influence"
        case .pairsWith: "pairs with"
        case .contrastsWith: "contrasts with"
        case .mentions: "mentioned alongside"
        }
    }
}

/// Recently opened entity pages, kept in memory so going back (or opening the same
/// page from somewhere else) shows it at once while a fresh copy loads.
final class EntityDetailStore {
    struct Cached {
        let detail: EntityDetail
        let page: EntityPage
        let viewer: String?
        let loadedAt: Date

        /// Recent enough to skip the network when returning to the page.
        var isFresh: Bool { Date().timeIntervalSince(loadedAt) < 60 }
    }

    static let shared = EntityDetailStore()

    private var entries: [String: Cached] = [:]
    private var order: [String] = []
    private let capacity = 24

    func cached(kind: EntityKind, id: String) -> Cached? {
        entries[Self.key(kind, id)]
    }

    /// Fetches, decodes, and prepares the page away from the main actor, then remembers it.
    func load(kind: EntityKind, id: String, api: APIClient, viewer: String?) async throws -> Cached {
        let (detail, page) = try await EntityLoading.fetch(api: api, kind: kind, id: id, viewer: viewer)
        let cached = Cached(detail: detail, page: page, viewer: viewer, loadedAt: Date())
        let key = Self.key(kind, id)
        entries[key] = cached
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
        return cached
    }

    private static func key(_ kind: EntityKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }
}

nonisolated enum EntityLoading {
    @concurrent
    static func fetch(api: APIClient, kind: EntityKind, id: String, viewer: String?) async throws -> (EntityDetail, EntityPage) {
        let detail = try await api.entity(kind: kind, id: id)
        return (detail, EntityPage(detail: detail, viewer: viewer))
    }
}

/// Links that open an entity in the person's streaming app. Apple Music and YouTube
/// Music search by name; Spotify and YouTube Music open the exact track when known.
enum EntityOpenInLinks {
    static func searchTerm(for entity: CatalogEntity, artist: Artist?) -> String {
        switch entity {
        case .artist, .genre: entity.name
        case .album, .song: [entity.name, artist?.name].compactMap { $0 }.joined(separator: " ")
        }
    }

    static func appleMusic(term: String) -> URL? {
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: term)]
        return components?.url
    }

    static func spotify(for entity: CatalogEntity, term: String) -> URL? {
        if case .song(let song) = entity, let spotifyId = song.spotifyId, !spotifyId.isEmpty {
            return URL(string: "https://open.spotify.com/track/\(spotifyId)")
        }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://open.spotify.com/search/\(encoded)")
    }

    static func youTubeMusic(for entity: CatalogEntity, term: String) -> URL? {
        if case .song(let song) = entity, let youtubeId = song.youtubeId, !youtubeId.isEmpty {
            var components = URLComponents(string: "https://music.youtube.com/watch")
            components?.queryItems = [URLQueryItem(name: "v", value: youtubeId)]
            return components?.url
        }
        var components = URLComponents(string: "https://music.youtube.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: term)]
        return components?.url
    }
}

extension NowPlayingService {
    /// Treats `song` as what's playing now and opens quick capture for it at once. When
    /// this device hasn't seen the song's artist yet, the song's page loads behind the
    /// sheet and the byline fills in when it arrives.
    func writeAboutNow(_ song: Song, origin: String, model: AppModel, router: Router) {
        model.absorb(.song(song))
        use(song: song)
        router.present(.capture(CapturePreset(origin: origin)))
        guard model.catalog.artists[song.artistId] == nil else { return }
        let api = model.api
        let viewer = model.profile?.id
        Task {
            guard let loaded = try? await EntityDetailStore.shared.load(kind: .song, id: song.id, api: api, viewer: viewer) else { return }
            model.absorb(loaded.detail)
        }
    }
}
