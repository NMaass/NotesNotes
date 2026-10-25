import ResonoteKit
import SwiftUI

/// A genre with its name folded for filtering, prepared once.
nonisolated struct GenreOption: Sendable, Identifiable {
    let genre: Genre
    let folded: String
    var id: String { genre.id }

    init(_ genre: Genre) {
        self.genre = genre
        folded = TrackText.fold(genre.name)
    }

    /// Alphabetical options for `genres`, prepared away from the main actor.
    @concurrent
    static func sorted(_ genres: [Genre]) async -> [GenreOption] {
        genres
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(GenreOption.init)
    }
}

/// Every genre the backend knows, loaded once per launch and kept in memory.
final class GenreDirectory {
    static let shared = GenreDirectory()

    private(set) var options: [GenreOption]?
    private(set) var byId: [String: Genre] = [:]

    func load(api: APIClient) async throws -> [GenreOption] {
        if let options { return options }
        let loaded = try await GenreLoading.fetch(api: api)
        options = loaded
        byId = Dictionary(loaded.map { ($0.id, $0.genre) }, uniquingKeysWith: { first, _ in first })
        return loaded
    }
}

nonisolated enum GenreLoading {
    @concurrent
    static func fetch(api: APIClient) async throws -> [GenreOption] {
        let genres = try await api.genres()
        return await GenreOption.sorted(genres)
    }
}

/// Assert personal genre tags. Tags stay attributed to the person who chose them.
struct GenreTagSheet: View {
    let kind: EntityKind
    let id: String

    @Environment(AppModel.self) private var model
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(\.dismiss) private var dismiss

    /// Set when the entity had to be loaded because this device hadn't seen it.
    @State private var fetched: CatalogEntity?
    @State private var genres: [GenreOption]?
    @State private var loadFailed = false
    @State private var lookupFailed = false
    @State private var lookupAttempt = 0
    @State private var filter = ""
    @State private var showsAll = false

    init(kind: EntityKind, id: String) {
        self.kind = kind
        self.id = id
        _genres = State(initialValue: GenreDirectory.shared.options)
    }

    private var entity: CatalogEntity? {
        model.catalog.entity(kind: kind, id: id) ?? fetched
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RN.Space.l) {
                    EntitySheetHeading(
                        title: "How do you hear “\(entity?.name ?? "this")”?",
                        message: "Choose genre labels that help describe it. Your assertion remains attributed to you instead of becoming an anonymous verdict."
                    )
                    content
                    Text("Catalog tags, community totals, and your own tags stay separate in storage. The page only combines them for a lighter reading surface.")
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, RN.Space.gutter)
                .padding(.bottom, RN.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a genre")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    EntitySheetCloseButton { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: "\(id)#\(lookupAttempt)") { await prepare() }
    }

    @ViewBuilder
    private var content: some View {
        if let entity {
            let mine = Set((model.bundle?.genreAssertions ?? []).filter { $0.entityId == entity.id }.map(\.genreId))
            let (suggested, rest) = options()
            if !suggested.isEmpty {
                group("Suggested", suggested, mine: mine, entity: entity)
            }
            if let genres {
                if !rest.isEmpty {
                    // Hundreds of chips laid out at once are slow: a page at a time unless filtering.
                    let page = filter.isEmpty && !showsAll ? Array(rest.prefix(Self.firstPage)) : rest
                    group(suggested.isEmpty ? "Genres" : "All genres", page, mine: mine, entity: entity)
                    if filter.isEmpty, rest.count > Self.firstPage {
                        Button(showsAll ? "Show fewer" : "Show all \(rest.count) genres") { showsAll.toggle() }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(RN.Palette.rustText)
                    }
                } else if suggested.isEmpty {
                    Text(filter.isEmpty || genres.isEmpty ? "No genres are available yet." : "No genre matches “\(filter)”.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                }
            } else {
                chipPlaceholder
            }
            if loadFailed {
                ReservedErrorRow(message: "The full genre list didn't load. Showing the ones on this device.")
            }
        } else if lookupFailed {
            EmptyStateView(title: "This page didn't load", message: "Resonote can't find this music right now. Try again in a moment.", actionTitle: "Try again") {
                lookupFailed = false
                lookupAttempt += 1
            }
        } else {
            chipPlaceholder
        }
    }

    private func group(_ title: String, _ options: [GenreOption], mine: Set<String>, entity: CatalogEntity) -> some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Eyebrow(title)
            FlowLayout {
                ForEach(options) { option in
                    Chip(option.genre.name, isSelected: mine.contains(option.genre.id)) {
                        toggle(option.genre, on: entity)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Your genre tags for \(entity.name)")
        }
    }

    private static let firstPage = 40

    private var chipPlaceholder: some View {
        FlowLayout {
            ForEach(Array([72.0, 104, 64, 88, 120, 76, 96, 68, 110, 84].enumerated()), id: \.offset) { _, width in
                Capsule().fill(RN.Palette.fill).frame(width: width, height: 34)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading genres")
    }

    /// Suggestions first (the entity's own tags, then what the now-playing match suggests),
    /// then every other genre alphabetically, both narrowed by the filter.
    private func options() -> (suggested: [GenreOption], rest: [GenreOption]) {
        let query = TrackText.fold(filter)
        var suggested: [GenreOption] = []
        var seen = Set<String>()
        if let cached = EntityDetailStore.shared.cached(kind: kind, id: id) {
            for tag in cached.detail.genres where seen.insert(tag.genre.id).inserted {
                suggested.append(GenreOption(tag.genre))
            }
        }
        if kind == .song, nowPlaying.song?.id == id {
            for suggestion in nowPlaying.suggestions.genres where seen.insert(suggestion.id).inserted {
                let genre = GenreDirectory.shared.byId[suggestion.id] ?? Genre(id: suggestion.id, name: suggestion.name, slug: Slug.make(suggestion.name))
                suggested.append(GenreOption(genre))
            }
        }
        let matches: (GenreOption) -> Bool = { query.isEmpty || $0.folded.contains(query) }
        let rest = (genres ?? []).filter { !seen.contains($0.id) && matches($0) }
        return (suggested.filter(matches), rest)
    }

    private func toggle(_ genre: Genre, on entity: CatalogEntity) {
        model.absorb(.genre(genre))
        model.toggleGenre(genre.id, on: entity)
    }

    private func prepare() async {
        if entity == nil {
            fetched = await model.ensureEntity(kind: kind, id: id)
            lookupFailed = fetched == nil
        }
        guard genres == nil else { return }
        do {
            genres = try await GenreDirectory.shared.load(api: model.api)
        } catch is CancellationError {
            return
        } catch {
            loadFailed = true
            genres = await GenreOption.sorted(Array(model.catalog.genres.values))
        }
    }
}
