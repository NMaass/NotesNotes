import Foundation
import ResonoteKit

/// The search tab's filters (the web's tabs).
enum CatalogSearchScope: String, CaseIterable, Hashable, Identifiable {
    case all, songs, albums, artists, genres

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .genres: "Genres"
        }
    }

    var kind: EntityKind? {
        switch self {
        case .all: nil
        case .songs: .song
        case .albums: .album
        case .artists: .artist
        case .genres: .genre
        }
    }

    /// What to look for on MusicBrainz: songs unless a narrower kind is chosen.
    /// MusicBrainz has no genre pages to import.
    var discoveryKind: EntityKind? {
        switch self {
        case .all, .songs: .song
        case .albums: .album
        case .artists: .artist
        case .genres: nil
        }
    }
}

/// Ranking shared by local matches and merged batches, mirroring the server's
/// `matchScore`: exact 100, prefix 70, contains 40, then by name.
nonisolated enum CatalogSearchRank {
    static func score(query: String, folded name: String) -> Int {
        guard !query.isEmpty else { return 0 }
        if name == query { return 100 }
        if name.hasPrefix(query) { return 70 }
        if name.contains(query) { return 40 }
        return 0
    }

    static func ordered(_ a: (score: Int, name: String), _ b: (score: Int, name: String)) -> Bool {
        if a.score != b.score { return a.score > b.score }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    /// Rows already on screen keep their places; rows only `incoming` has follow, in its
    /// order. Used when a batch arrives after the person may have started aiming at a row.
    static func appending(_ incoming: [SearchResult], to shown: [SearchResult], kind: EntityKind?, limit: Int) -> [SearchResult] {
        let shownIds = Set(shown.map(\.id))
        var seen = shownIds
        let added = incoming.filter { result in
            (kind == nil || result.entity.kind == kind) && seen.insert(result.id).inserted
        }
        return Array((shown + added).prefix(max(limit, shown.count)))
    }

    /// One complete batch: local and server results together, deduplicated by id and
    /// ordered by each row's own score, so rows already on screen keep their relative order.
    static func merge(query: String, local: [SearchResult], server: [SearchResult], kind: EntityKind?, limit: Int) -> [SearchResult] {
        var byId: [String: SearchResult] = [:]
        var order: [String] = []
        for result in local where kind == nil || result.entity.kind == kind {
            if byId[result.id] == nil { order.append(result.id) }
            byId[result.id] = result
        }
        for var result in server where kind == nil || result.entity.kind == kind {
            if let existing = byId[result.id] {
                if result.subtitle.isEmpty { result.subtitle = existing.subtitle }
            } else {
                order.append(result.id)
            }
            byId[result.id] = result
        }
        let scored: [(result: SearchResult, score: Int, name: String)] = order.compactMap { id in
            guard let result = byId[id] else { return nil }
            // Every row here already matched (the server also matches aliases such as "mbv");
            // a row whose own name doesn't contain the query ranks with "contains" matches.
            let score = max(Self.score(query: query, folded: TrackText.fold(result.entity.name)), 40)
            return (result, score, result.entity.name)
        }
        return Array(scored.sorted { ordered(($0.score, $0.name), ($1.score, $1.name)) }.prefix(limit).map(\.result))
    }
}

/// Every catalog row on this device with its name folded once, for instant matches
/// while the server search is on its way.
nonisolated struct LocalCatalogSearch: Sendable {
    nonisolated struct Signature: Equatable, Sendable {
        var artists = -1
        var albums = -1
        var songs = -1
        var genres = -1

        init() {}

        init(_ catalog: CatalogIndex) {
            artists = catalog.artists.count
            albums = catalog.albums.count
            songs = catalog.songs.count
            genres = catalog.genres.count
        }
    }

    nonisolated struct Item: Sendable {
        let entity: CatalogEntity
        let folded: String
    }

    let signature: Signature
    private let items: [Item]

    init() {
        signature = Signature()
        items = []
    }

    private init(signature: Signature, items: [Item]) {
        self.signature = signature
        self.items = items
    }

    @concurrent
    static func build(_ catalog: CatalogIndex) async -> LocalCatalogSearch {
        var items: [Item] = []
        items.reserveCapacity(catalog.artists.count + catalog.albums.count + catalog.songs.count + catalog.genres.count)
        for artist in catalog.artists.values { items.append(Item(entity: .artist(artist), folded: TrackText.fold(artist.name))) }
        for album in catalog.albums.values { items.append(Item(entity: .album(album), folded: TrackText.fold(album.name))) }
        for song in catalog.songs.values { items.append(Item(entity: .song(song), folded: TrackText.fold(song.name))) }
        for genre in catalog.genres.values { items.append(Item(entity: .genre(genre), folded: TrackText.fold(genre.name))) }
        return LocalCatalogSearch(signature: Signature(catalog), items: items)
    }

    /// The best `limit` matches for an already folded query.
    @concurrent
    func matches(_ query: String, kind: EntityKind?, limit: Int) async -> [CatalogEntity] {
        guard !query.isEmpty else { return [] }
        var exact: [CatalogEntity] = []
        var prefix: [CatalogEntity] = []
        var contains: [CatalogEntity] = []
        for item in items where kind == nil || item.entity.kind == kind {
            switch CatalogSearchRank.score(query: query, folded: item.folded) {
            case 100: exact.append(item.entity)
            case 70: prefix.append(item.entity)
            case 40: contains.append(item.entity)
            default: break
            }
        }
        // Sort only as many buckets as the limit needs.
        var ranked: [CatalogEntity] = []
        for bucket in [exact, prefix, contains] where ranked.count < limit {
            let sorted = bucket.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            ranked.append(contentsOf: sorted.prefix(limit - ranked.count))
        }
        return ranked
    }
}

/// One local search index for the app (the Search tab and `\` references), built off
/// the main actor and rebuilt only when the catalog changes.
final class LocalCatalogIndex {
    static let shared = LocalCatalogIndex()

    private var index = LocalCatalogSearch()
    private var revision = -1
    private var building: (revision: Int, task: Task<LocalCatalogSearch, Never>)?

    /// The index for `catalog` at `revision` (`AppModel.catalogRevision`).
    func current(for catalog: CatalogIndex, revision: Int) async -> LocalCatalogSearch {
        if revision == self.revision { return index }
        if let building, building.revision == revision { return await building.task.value }
        let task = Task { await LocalCatalogSearch.build(catalog) }
        building = (revision, task)
        let built = await task.value
        if building?.revision == revision { building = nil }
        if revision > self.revision {
            index = built
            self.revision = revision
        }
        return built
    }
}

/// What the search tab remembers between keystrokes without redrawing: recent server
/// batches, so backspacing or returning to the tab is instant.
final class CatalogSearchMemo {
    private var batches: [String: [SearchResult]] = [:]
    private var discoveries: [String: [SearchResult]] = [:]
    private let capacity = 60

    func batch(for query: String, limit: Int) -> [SearchResult]? {
        batches["\(limit)|\(query)"]
    }

    func store(_ results: [SearchResult], for query: String, limit: Int) {
        if batches.count >= capacity { batches.removeAll() }
        batches["\(limit)|\(query)"] = results
    }

    func discovery(for query: String, kind: EntityKind) -> [SearchResult]? {
        discoveries["\(kind.rawValue)|\(query)"]
    }

    func storeDiscovery(_ results: [SearchResult], for query: String, kind: EntityKind) {
        if discoveries.count >= capacity { discoveries.removeAll() }
        discoveries["\(kind.rawValue)|\(query)"] = results
    }

    /// After an import the catalog has new rows, so remembered answers are stale.
    func forgetResults() {
        batches.removeAll()
        discoveries.removeAll()
    }
}
