import ResonoteKit
import SwiftUI

/// The Search tab: instant matches from this device, the shared catalog a moment
/// later, and MusicBrainz when the catalog has little to offer.
///
/// Results arrive as whole batches. While a new batch is on its way the previous one
/// stays on screen; rows already shown keep their places and server-only rows follow
/// them, so nothing moves under a finger.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying

    @State private var query = ""
    @State private var scope: CatalogSearchScope = .all
    @State private var memo = CatalogSearchMemo()
    @State private var rows: [Row] = []
    /// The search whose catalog batch is on screen.
    @State private var settledKey: Key?
    @State private var localCount = 0
    @State private var catalogUnreachable = false
    @State private var discovery = Discovery()
    @State private var revision = 0
    @State private var importingId: String?
    @State private var importError: String?
    @State private var imported = 0

    struct Key: Hashable {
        let text: String
        let folded: String
        let scope: CatalogSearchScope
        let revision: Int

        /// MusicBrainz is worth asking only for real words, and never for genres.
        var discoveryKind: EntityKind? {
            folded.count >= 3 ? scope.discoveryKind : nil
        }
    }

    struct Row: Identifiable {
        let result: SearchResult
        let subtitle: String
        let artworkURL: String?
        var id: String { result.id }
    }

    struct Discovery {
        var results: [SearchResult] = []
        /// The search MusicBrainz last answered (or was skipped for).
        var resolvedKey: Key?
        var failed = false
    }

    private static let examples = ["Lithium", "Nevermind", "Nirvana", "shoegaze"]

    private var key: Key {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Key(text: text, folded: TrackText.fold(text), scope: scope, revision: revision)
    }

    var body: some View {
        let key = key
        List {
            if key.text.isEmpty {
                guidance
                    .searchRowStyle()
            } else {
                results(for: key)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .paperBackground()
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Search artists, albums, songs, or genres")
        .searchScopes($scope) {
            ForEach(CatalogSearchScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .task(id: key) { await searchCatalog(key) }
        .task(id: key) { await searchMusicBrainz(key) }
        .sensoryFeedback(.success, trigger: imported)
    }

    // MARK: Content

    private var guidance: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            Text("Find something you have thoughts about.")
                .font(RN.Typography.headline)
                .foregroundStyle(RN.Palette.ink)
            Text("Try “Lithium,” “Nevermind,” “Nirvana,” or “shoegaze.”")
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
            FlowLayout {
                ForEach(Self.examples, id: \.self) { example in
                    Chip(example) { query = example }
                        .accessibilityHint("Searches for \(example)")
                }
            }
            .padding(.top, RN.Space.xs)
        }
        .padding(.vertical, RN.Space.l)
    }

    @ViewBuilder
    private func results(for key: Key) -> some View {
        let settled = settledKey == key
        let showsDiscoveryRows = !(settled && rows.count >= 5)
        let found = showsDiscoveryRows ? discoveryRows : []
        let discoveryKind = key.discoveryKind
        let resolved = discovery.resolvedKey == key

        if !settled, rows.isEmpty {
            // The first batch is on its way: rows at their final height, not a blank list.
            ForEach(0..<4, id: \.self) { index in
                CatalogRowPlaceholder(artworkSize: 46)
                    .accessibilityHidden(index > 0)
                    .accessibilityLabel("Searching")
                    .searchRowStyle()
            }
        }

        ForEach(rows) { row in
            Button {
                open(row.result.entity)
            } label: {
                EntityRow(entity: row.result.entity, subtitle: row.subtitle, artworkURL: row.artworkURL)
            }
            .contextMenu {
                if case .song(let song) = row.result.entity {
                    Button("Write about this now", systemImage: "record.circle") { writeNow(song) }
                }
            }
            .searchRowStyle()
        }

        if catalogUnreachable, settled {
            Text("Resonote can't be reached right now. Showing music on this device.")
                .font(.footnote)
                .foregroundStyle(RN.Palette.muted)
                .searchRowStyle()
        }

        if discoveryKind != nil {
            if !found.isEmpty {
                Section {
                    ForEach(found) { result in
                        discoveryRow(result)
                    }
                    ReservedErrorRow(message: importError)
                        .searchRowStyle()
                } header: {
                    Eyebrow("From MusicBrainz")
                }
            } else if resolved, discovery.failed {
                Section {
                    Text("MusicBrainz is unavailable. Local search still works.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .searchRowStyle()
                } header: {
                    Eyebrow("From MusicBrainz")
                }
            } else if settled, rows.count < 5, !resolved {
                Section {
                    Text("Looking beyond your local catalog…")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .searchRowStyle()
                        .accessibilityAddTraits(.updatesFrequently)
                } header: {
                    Eyebrow("From MusicBrainz")
                }
            }
        }

        if settled, rows.isEmpty, found.isEmpty, discoveryKind == nil || resolved {
            Text("No matching music yet.")
                .font(RN.Typography.headline)
                .foregroundStyle(RN.Palette.muted)
                .padding(.vertical, RN.Space.l)
                .searchRowStyle()
        }
    }

    /// MusicBrainz results not already in the catalog results (same name and kind).
    private var discoveryRows: [SearchResult] {
        let shown = Set(rows.map { "\($0.result.entity.kind.rawValue)|\(TrackText.fold($0.result.entity.name))" })
        return discovery.results.filter { !shown.contains("\($0.entity.kind.rawValue)|\(TrackText.fold($0.entity.name))") }
    }

    private func discoveryRow(_ result: SearchResult) -> some View {
        let isImporting = importingId == result.id
        return Button {
            importResult(result)
        } label: {
            HStack(spacing: RN.Space.m) {
                EntityRow(entity: result.entity, subtitle: result.subtitle, artworkURL: result.entity.imageUrl, trailing: "")
                StableLabel(isImporting ? "Importing…" : "Import", among: ["Import", "Importing…"])
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RN.Palette.rustText)
            }
        }
        .disabled(importingId != nil && !isImporting)
        .accessibilityHint("Brings it into Resonote from MusicBrainz and opens its page")
        .searchRowStyle()
    }

    // MARK: Actions

    private func open(_ entity: CatalogEntity) {
        model.absorb(entity)
        router.push(.entity(kind: entity.kind, id: entity.id))
    }

    private func writeNow(_ song: Song) {
        nowPlaying.writeAboutNow(song, origin: "search", model: model, router: router)
    }

    private func importResult(_ result: SearchResult) {
        guard importingId == nil, let mbid = result.entity.musicbrainzId else { return }
        let kind = result.entity.kind
        importingId = result.id
        importError = nil
        Task {
            do {
                let slice = try await model.api.importFromMusicBrainz(kind: kind, mbid: mbid)
                model.absorb(slice)
                importingId = nil
                memo.forgetResults()
                revision += 1
                guard let focus = Self.focus(in: slice, kind: kind, mbid: mbid) else {
                    importError = "Imported, but its page isn't ready yet. Search again in a moment."
                    return
                }
                imported += 1
                // Open the page only if the person is still here; elsewhere, the result simply waits in Search.
                guard router.tab == .search, router.sheet == nil else { return }
                router.push(.entity(kind: focus.kind, id: focus.id))
            } catch {
                importingId = nil
                guard !(error is CancellationError) else { return }
                importError = (error as? LocalizedError)?.errorDescription ?? "Import failed."
            }
        }
    }

    /// The imported row the person picked: matched by MusicBrainz id, else the first of its kind.
    private static func focus(in slice: CatalogSlice, kind: EntityKind, mbid: String) -> CatalogEntity? {
        switch kind {
        case .artist: (slice.artists.first { $0.musicbrainzId == mbid } ?? slice.artists.first).map(CatalogEntity.artist)
        case .album: (slice.albums.first { $0.musicbrainzId == mbid } ?? slice.albums.first).map(CatalogEntity.album)
        case .song: (slice.songs.first { $0.musicbrainzId == mbid } ?? slice.songs.first).map(CatalogEntity.song)
        case .genre: (slice.genres.first { $0.musicbrainzId == mbid } ?? slice.genres.first).map(CatalogEntity.genre)
        }
    }

    // MARK: Searching

    /// Local matches at once, then the shared catalog after a short pause. Rows already
    /// on screen keep their places and the catalog's other rows follow; a remembered
    /// batch shows ranked in one go. A newer keystroke cancels this through `task(id:)`.
    private func searchCatalog(_ key: Key) async {
        guard !key.folded.isEmpty else {
            rows = []
            localCount = 0
            catalogUnreachable = false
            settledKey = key
            return
        }
        let catalog = model.catalog
        let index = await LocalCatalogIndex.shared.current(for: catalog, revision: model.catalogRevision)
        let matches = await index.matches(key.folded, kind: key.scope.kind, limit: 14)
        guard !Task.isCancelled else { return }
        let local = matches.map { SearchResult(entity: $0, subtitle: catalog.subtitle(for: $0), source: .local) }
        localCount = local.count
        let limit = key.scope == .all ? 30 : 50
        let cacheKey = key.folded

        if let remembered = memo.batch(for: cacheKey, limit: limit) {
            show(CatalogSearchRank.merge(query: key.folded, local: local, server: remembered, kind: key.scope.kind, limit: limit), settling: key)
            return
        }
        if !local.isEmpty {
            rows = makeRows(local)
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let server = try await model.api.searchCatalog(key.text, limit: limit)
            memo.store(server, for: cacheKey, limit: limit)
            catalogUnreachable = false
            let batch = local.isEmpty
                ? CatalogSearchRank.merge(query: key.folded, local: [], server: server, kind: key.scope.kind, limit: limit)
                : CatalogSearchRank.appending(server, to: local, kind: key.scope.kind, limit: limit)
            show(batch, settling: key)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            catalogUnreachable = true
            show(local, settling: key)
        }
    }

    private func show(_ results: [SearchResult], settling key: Key) {
        rows = makeRows(results)
        settledKey = key
        if rows.count >= 5, discovery.resolvedKey != key {
            discovery = Discovery(results: [], resolvedKey: key, failed: false)
        }
    }

    private func makeRows(_ results: [SearchResult]) -> [Row] {
        results.map { result in
            Row(
                result: result,
                subtitle: result.subtitle.isEmpty ? model.catalog.subtitle(for: result.entity) : result.subtitle,
                artworkURL: model.catalog.artworkURL(for: result.entity)
            )
        }
    }

    /// MusicBrainz, after a longer pause, only when the catalog found fewer than five.
    private func searchMusicBrainz(_ key: Key) async {
        guard let kind = key.discoveryKind else {
            discovery = Discovery(results: [], resolvedKey: key, failed: false)
            return
        }
        if let remembered = memo.discovery(for: key.folded, kind: kind) {
            discovery = Discovery(results: remembered, resolvedKey: key, failed: false)
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(420))
        } catch {
            return
        }
        let found = settledKey == key ? rows.count : localCount
        guard found < 5 else {
            discovery = Discovery(results: [], resolvedKey: key, failed: false)
            return
        }
        do {
            let results = try await model.api.searchMusicBrainz(key.text, kind: kind)
            memo.storeDiscovery(results, for: key.folded, kind: kind)
            discovery = Discovery(results: results, resolvedKey: key, failed: false)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            discovery = Discovery(results: [], resolvedKey: key, failed: true)
        }
    }
}

private extension View {
    func searchRowStyle() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparatorTint(RN.Palette.line)
            .listRowInsets(EdgeInsets(top: 8, leading: RN.Space.gutter, bottom: 8, trailing: RN.Space.gutter))
    }
}
