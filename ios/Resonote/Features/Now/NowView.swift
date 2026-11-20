import ResonoteKit
import SwiftUI

/// The Now tab: the record and what's playing, one invitation to write about it, then
/// the person's recent listening as one plain list. Drafts and notes live in Journal;
/// writing others published is in the More menu (`Route.feed`).
struct NowView: View {
    @Environment(AppModel.self) private var model
    @Environment(NowPlayingService.self) private var nowPlaying

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RN.Space.xl) {
                NowPlayingCard()
                NowRecentPlays()
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.bottom, RN.Space.xxl)
        }
        .paperBackground()
        .navigationTitle("Now")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if nowPlaying.copiedLinkAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    NowPasteButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NowActionsMenu()
            }
        }
        .refreshable { await refreshAll() }
        .onAppear {
            // Reuses a sample from the last few seconds; Apple Music notifications cover real changes.
            nowPlaying.scheduleRefresh()
        }
    }

    private func refreshAll() async {
        async let playing: Void = nowPlaying.refresh()
        async let own: Void = model.refreshSession()
        _ = await (playing, own)
    }
}

// MARK: - Recently played

/// The owner's newest logged listens, derived once per data change.
private struct NowListenDigest {
    struct Input: Equatable {
        var listens: [ListenLog]
    }

    let listens: [ListenLog]
    let refs: [CatalogRef]

    static let limit = 6

    init(_ input: Input) {
        listens = Array(JournalOrder.listenDays(input.listens).flatMap(\.listens).prefix(Self.limit))
        refs = listens.map { CatalogRef(kind: .song, id: $0.songId) }
    }
}

/// "Recently played": one plain list with inset separators, no card. Signed out it is
/// left out: the Journal tab is where you sign in, and nothing crowds the bar above the tabs.
private struct NowRecentPlays: View {
    @Environment(AppModel.self) private var model
    @State private var memo = JournalMemo<NowListenDigest.Input, NowListenDigest>()
    @State private var unavailable: Set<String> = []

    var body: some View {
        if let bundle = model.bundle {
            let digest = memo.value(for: NowListenDigest.Input(listens: bundle.listens), NowListenDigest.init)
            VStack(alignment: .leading, spacing: RN.Space.xs) {
                Text("Recently played")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(RN.Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if digest.listens.isEmpty {
                    Text("Songs you note or log show up here.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .padding(.vertical, RN.Space.s)
                } else {
                    VStack(spacing: 0) {
                        ForEach(digest.listens) { listen in
                            NowListenRow(listen: listen, isUnavailable: unavailable.contains(listen.songId))
                            if listen.id != digest.listens.last?.id {
                                Divider()
                                    .overlay(RN.Palette.line)
                                    .padding(.leading, NowListenRow.textInset)
                            }
                        }
                    }
                }
            }
            .loadsMissingCatalog(digest.refs, unavailable: $unavailable)
        }
    }
}

/// One logged listen, compact: the song, its moods or note, and when.
private struct NowListenRow: View {
    let listen: ListenLog
    let isUnavailable: Bool

    /// Where the separator starts: past the artwork, under the text.
    static let textInset: CGFloat = 44 + RN.Space.m

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        if let song = model.catalog.songs[listen.songId] {
            Button {
                router.push(.entity(kind: .song, id: song.id))
            } label: {
                content(song)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the song")
        } else {
            CatalogRowPlaceholder(artworkSize: 44, isUnavailable: isUnavailable)
                .padding(.vertical, RN.Space.m)
        }
    }

    private func content(_ song: Song) -> some View {
        let entity = CatalogEntity.song(song)
        return HStack(spacing: RN.Space.m) {
            ArtworkView(model.catalog.artworkURL(for: entity), title: song.name, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text(detail(entity))
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: RN.Space.s)
            if let date = ResonoteDate.parse(listen.listenedAt) {
                Text(NowRelativeTime.phrase(since: date, now: .now))
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, RN.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The note, else the moods, else "Artist · Album".
    private func detail(_ entity: CatalogEntity) -> String {
        if let note = listen.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty { return note }
        if !listen.moods.isEmpty { return listen.moods.joined(separator: " · ") }
        return model.catalog.subtitle(for: entity)
    }
}
