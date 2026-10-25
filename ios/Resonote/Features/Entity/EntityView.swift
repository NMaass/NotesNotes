import ResonoteKit
import SwiftUI

/// An artist, album, song, or genre page.
///
/// The header draws from the local catalog at once; the rest of the page arrives in one
/// batch from `GET /api/catalog/entity`. Recently opened pages are kept in memory, so
/// going back shows them instantly while a refresh replaces them in place.
struct EntityView: View {
    let kind: EntityKind
    let id: String

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying

    @State private var page: EntityPage?
    @State private var problem: Problem?
    @State private var showsTitle = false

    private enum Problem: Equatable {
        case notFound
        case failed(String)
    }

    private struct LoadKey: Hashable {
        let kind: EntityKind
        let id: String
        let viewer: String?
    }

    init(kind: EntityKind, id: String) {
        self.kind = kind
        self.id = id
        _page = State(initialValue: EntityDetailStore.shared.cached(kind: kind, id: id)?.page)
    }

    var body: some View {
        let shown = page ?? model.catalog.entity(kind: kind, id: id).map { EntityPage(seed: $0, catalog: model.catalog) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RN.Space.xl) {
                if let shown {
                    EntityHeader(page: shown, isPlaying: isPlaying)
                    EntityActions(page: shown)
                    if shown.isComplete {
                        sections(shown)
                    } else {
                        if let problem {
                            problemView(problem)
                        } else {
                            EntitySectionsPlaceholder()
                        }
                        // The person's own writing is on this device; it doesn't wait for the page.
                        let own = ownEntries
                        if !own.isEmpty {
                            EntityOwnEntries(entries: own)
                        }
                    }
                } else if let problem {
                    problemView(problem)
                } else {
                    EntityHeaderPlaceholder(kind: kind)
                    EntitySectionsPlaceholder()
                }
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.top, RN.Space.s)
            .padding(.bottom, RN.Space.xxl)
        }
        .paperBackground()
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 260
        } action: { _, past in
            showsTitle = past
        }
        .navigationTitle(shown?.name ?? kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(shown?.name ?? "")
                    .font(.headline)
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                    .opacity(showsTitle ? 1 : 0)
                    .animation(RN.Motion.quick, value: showsTitle)
                    .accessibilityHidden(!showsTitle)
            }
            .sharedBackgroundVisibility(.hidden)
            if case .song(let song)? = shown?.entity {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Write about this now", systemImage: "record.circle") {
                        writeNow(song)
                    }
                }
            }
        }
        .refreshable { await load(force: true) }
        .task(id: LoadKey(kind: kind, id: id, viewer: model.profile?.id)) {
            await load(force: false)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(_ page: EntityPage) -> some View {
        let chips = EntityGenreChip.items(for: page, model: model, directory: GenreDirectory.shared.byId)
        if !chips.isEmpty {
            EntityGenreChipRow(items: chips)
        }
        switch page.entity {
        case .album:
            if !page.tracklist.isEmpty {
                EntityTracklistSection(tracks: page.tracklist, onWriteNow: writeNow)
            }
        case .artist:
            if !page.albums.isEmpty {
                EntityAlbumGrid(eyebrow: "Release groups", title: "Albums", albums: page.albums)
            }
            if !page.songs.isEmpty {
                EntitySongList(eyebrow: "Recordings", title: "Songs", songs: page.songs, onWriteNow: writeNow)
            }
        case .genre(let genre):
            EntityGenreIntro(description: genre.description, taggedSummary: page.taggedSummary)
            if !page.albums.isEmpty {
                EntityAlbumGrid(eyebrow: "Tagged albums", title: "Heard as \(genre.name)", albums: page.albums)
            }
            if !page.songs.isEmpty {
                EntitySongList(eyebrow: "Tagged songs", title: "Songs", songs: page.songs, onWriteNow: writeNow)
            }
        case .song:
            EntitySongInfoRows(credits: page.credits.count, facts: page.facts.count) { info in
                switch info {
                case .credits: router.present(.songCredits(songId: id, songName: page.name, credits: page.credits))
                case .facts: router.present(.songFacts(songId: id, songName: page.name, facts: page.facts))
                }
            }
        }
        if !page.connections.isEmpty {
            EntityConnections(connections: page.connections)
        }
        let own = ownEntries
        if !own.isEmpty {
            EntityOwnEntries(entries: own)
        }
        let profileId = model.profile?.id
        EntityPublicEntries(
            entries: page.entries.filter { $0.profileId != profileId && !model.isBlocked($0.profileId) },
            authors: page.authors,
            write: write
        )
    }

    @ViewBuilder
    private func problemView(_ problem: Problem) -> some View {
        switch problem {
        case .notFound:
            EmptyStateView(
                title: "This one hasn't been brought in yet",
                message: "Resonote’s crate grows when listeners import records from MusicBrainz. Nobody has claimed this release yet — its liner notes are still unwritten.",
                actionTitle: "Search",
                action: { router.tab = .search }
            )
        case .failed(let message):
            EmptyStateView(
                title: "This page didn't load",
                message: message,
                actionTitle: "Try again",
                action: { Task { await load(force: true) } }
            )
        }
    }

    // MARK: Actions

    /// The signed-in person's entries about this entity, private ones included.
    private var ownEntries: [JournalEntry] {
        guard let profileId = model.profile?.id else { return [] }
        return model.entries(about: id).filter { $0.profileId == profileId }
    }

    /// Spins the record only while a source vouches for playback of this very song.
    private var isPlaying: Bool {
        kind == .song && nowPlaying.song?.id == id && nowPlaying.isConfirmedPlaying
    }

    private func write() {
        router.present(.compose(ComposerContext(entityKind: kind, entityId: id)))
    }

    private func writeNow(_ song: Song) {
        nowPlaying.writeAboutNow(song, origin: "entity", model: model, router: router)
    }

    // MARK: Loading

    private func load(force: Bool) async {
        let viewer = model.profile?.id
        let store = EntityDetailStore.shared
        if !force, let cached = store.cached(kind: kind, id: id), cached.isFresh, cached.viewer == viewer {
            if page == nil { page = cached.page }
            return
        }
        do {
            let loaded = try await store.load(kind: kind, id: id, api: model.api, viewer: viewer)
            model.absorb(loaded.detail)
            page = loaded.page
            problem = nil
        } catch is CancellationError {
            return
        } catch APIError.server(let status, _) where status == 404 {
            if page == nil { problem = .notFound }
        } catch {
            // A page already on screen stays; only an empty page shows the failure.
            if page == nil {
                problem = .failed((error as? LocalizedError)?.errorDescription ?? "Resonote can't be reached right now.")
            }
        }
    }
}
