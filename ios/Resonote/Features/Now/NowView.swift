import ResonoteKit
import SwiftUI

/// The Now tab: what's playing and an invitation to write about it, unfinished
/// drafts, and recent public observations from everyone.
struct NowView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(\.scenePhase) private var scenePhase

    @State private var feed = NowFeed()
    @State private var drafts: [NowDraftRow] = []
    @State private var hasReadDrafts = false
    @State private var draftReads = 0

    private static let draftLimit = 3

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RN.Space.l) {
                header
                NowPlayingCard()
                if !drafts.isEmpty {
                    NowDraftsSection(drafts: drafts)
                        .padding(.top, RN.Space.s)
                }
                NowFeedSection(feed: feed)
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.bottom, RN.Space.xxl)
        }
        .paperBackground()
        .navigationTitle("Now")
        .toolbarVisibility(.hidden, for: .navigationBar)
        .refreshable { await refreshAll() }
        .onAppear {
            // Reuses a sample from the last few seconds; Apple Music notifications cover real changes.
            nowPlaying.scheduleRefresh()
            if hasReadDrafts {
                draftReads += 1
            } else {
                // The first read is inline (three small files), so the section is there with the first frame.
                hasReadDrafts = true
                drafts = Self.draftRows(NowDrafts.read(limit: Self.draftLimit, from: model.drafts), catalog: model.catalog)
            }
        }
        .task { await feed.appear(model: model) }
        .task(id: draftReads) {
            guard draftReads > 0 else { return }
            await reloadDrafts()
        }
        .onChange(of: router.sheet) { _, sheet in
            if sheet == nil { draftReads += 1 }
        }
        // The share extension may have kept a draft while the app was away.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { draftReads += 1 }
        }
        // Drafts belong to whoever is signed in.
        .onChange(of: model.ownerId) { _, _ in draftReads += 1 }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RN.Space.xs) {
            Eyebrow("Listening")
            Text("Describe what you hear.")
                .font(RN.Typography.title)
                .foregroundStyle(RN.Palette.ink)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, RN.Space.l)
    }

    private func refreshAll() async {
        async let playing: Void = nowPlaying.refresh()
        async let writing: Void = feed.reload(model: model)
        _ = await (playing, writing)
        await reloadDrafts()
    }

    /// Reads the newest drafts away from the main actor and swaps the rows in one batch.
    private func reloadDrafts() async {
        let found = await NowDrafts.load(limit: Self.draftLimit, from: model.drafts)
        guard !Task.isCancelled else { return }
        let rows = Self.draftRows(found, catalog: model.catalog)
        if rows != drafts { drafts = rows }
    }

    private static func draftRows(_ drafts: [Draft], catalog: CatalogIndex) -> [NowDraftRow] {
        let now = Date()
        return drafts.map { NowDraftRow(draft: $0, catalog: catalog, now: now) }
    }
}

/// The newest drafts with words in them, decoding only as many files as needed.
nonisolated enum NowDrafts {
    static func read(limit: Int, from store: DraftStore) -> [Draft] {
        store.recent(limit: limit) { draft in
            !draft.document.isBlank || !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @concurrent
    static func load(limit: Int, from store: DraftStore) async -> [Draft] {
        read(limit: limit, from: store)
    }
}

// MARK: - Drafts

/// A draft as the Now tab shows it, with every string precomputed.
struct NowDraftRow: Identifiable, Equatable {
    let id: String
    let kind: EntityKind
    let entityId: String
    let entryId: String?
    /// Words about a song not matched yet: opening it matches the song first.
    let unmatchedTrack: NowPlayingTrack?
    let name: String
    let preview: String
    let artworkURL: String?
    let edited: String

    init(draft: Draft, catalog: CatalogIndex, now: Date) {
        let entity = draft.isUnmatched ? nil : catalog.entity(kind: draft.entityKind, id: draft.entityId)
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = draft.document.plainText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        id = draft.key
        kind = draft.entityKind
        entityId = draft.entityId
        entryId = draft.entryId
        unmatchedTrack = draft.isUnmatched ? draft.track : nil
        name = entity?.name ?? draft.track?.title ?? (title.isEmpty ? "\(draft.entityKind.label) draft" : title)
        preview = firstLine.isEmpty ? (title.isEmpty ? "No words yet" : title) : firstLine
        artworkURL = entity.flatMap { catalog.artworkURL(for: $0) } ?? draft.track?.artworkURL
        let age = NowRelativeTime.phrase(since: draft.updatedAt, now: now)
        if draft.isUnmatched {
            edited = "Not matched yet · \(age)"
        } else {
            edited = draft.entryId == nil ? age : "Editing · \(age)"
        }
    }
}

private struct NowDraftsSection: View {
    let drafts: [NowDraftRow]

    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            SectionHeader(eyebrow: "Unfinished", title: "Drafts")
            VStack(spacing: 0) {
                ForEach(drafts) { row in
                    Button {
                        open(row)
                    } label: {
                        NowDraftRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the draft")
                    if row.id != drafts.last?.id {
                        Divider().overlay(RN.Palette.line)
                    }
                }
            }
            .padding(.horizontal, RN.Space.l)
            .cardSurface()
        }
    }

    private func open(_ row: NowDraftRow) {
        if let track = row.unmatchedTrack {
            // Match the song first; once it is, the words join that song's draft.
            nowPlaying.present(track)
            router.present(.capture(CapturePreset(origin: "draft")))
        } else {
            router.present(.compose(ComposerContext(entityKind: row.kind, entityId: row.entityId, entryId: row.entryId)))
        }
    }
}

private struct NowDraftRowView: View {
    let row: NowDraftRow

    var body: some View {
        HStack(spacing: RN.Space.m) {
            ArtworkView(row.artworkURL, title: row.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text(row.preview)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: RN.Space.s)
            Text(row.edited)
                .font(.caption)
                .foregroundStyle(RN.Palette.muted)
                .lineLimit(1)
        }
        .padding(.vertical, RN.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Feed

/// "Recent observations": its children sit directly in the page's lazy stack, so
/// cards are built only as they scroll into view.
private struct NowFeedSection: View {
    let feed: NowFeed

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    private static let skeletonCount = 3

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            SectionHeader(eyebrow: "Recent observations", title: "Writing, not scoring")
            // New writing waits here, in the header's own line, instead of pushing cards down.
            if feed.newCount > 0 {
                Button(feed.newCount == 1 ? "1 new" : "\(feed.newCount) new") {
                    feed.showNew()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RN.Palette.rustText)
                .accessibilityHint("Shows the newest writing at the top")
            }
        }
        .padding(.top, RN.Space.l)

        let entries = feed.entries.filter { !model.isBlocked($0.profileId) }
        if entries.isEmpty {
            switch feed.status {
            case .idle, .loading:
                ForEach(0..<Self.skeletonCount, id: \.self) { index in
                    NowEntrySkeleton(announces: index == 0)
                }
            case .failed:
                NowFeedErrorRow {
                    Task { await feed.reload(model: model) }
                }
            case .loaded:
                EmptyStateView(
                    title: "The first observation can be yours.",
                    message: "Note what's playing above, or find a song in Search, then write what you noticed without assigning it a score."
                )
            }
        } else {
            let lastId = entries.last?.id
            ForEach(entries) { entry in
                card(for: entry)
                    .onAppear {
                        guard entry.id == lastId else { return }
                        Task { await feed.loadMore(model: model) }
                    }
            }
            if feed.nextCursor != nil {
                footer
            }
        }
    }

    private func card(for entry: JournalEntry) -> some View {
        let entity = model.catalog.entity(kind: entry.entityKind, id: entry.entityId)
        return EntryCard(
            entry: entry,
            author: model.author(of: entry),
            entity: entity,
            artworkURL: entity.flatMap { model.catalog.artworkURL(for: $0) },
            onOpen: { router.push(.entry(id: entry.id)) }
        )
    }

    /// Reserved height whether it is loading, failed, or waiting for the last card.
    private var footer: some View {
        ZStack {
            ProgressView()
                .nowStateLayer(visible: feed.isLoadingMore)
            HStack(spacing: RN.Space.s) {
                Text("More writing didn't load.")
                    .foregroundStyle(RN.Palette.muted)
                Button("Retry") {
                    Task { await feed.loadMore(model: model) }
                }
                .fontWeight(.semibold)
                .foregroundStyle(RN.Palette.rustText)
            }
            .font(.footnote)
            .nowStateLayer(visible: feed.loadMoreFailed && !feed.isLoadingMore)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// An entry card shape with stand-in text, redacted, so the feed's geometry is set before it loads.
private struct NowEntrySkeleton: View {
    let announces: Bool

    private static let entry = JournalEntry(
        id: "skeleton",
        profileId: "",
        entityId: "",
        entityKind: .song,
        document: .plain("A few lines about a song, long enough to fill the card the way a real observation does once it arrives, with room for a second thought."),
        plainText: "",
        lenses: [.feeling, .production],
        createdAt: "",
        updatedAt: ""
    )
    private static let author = Profile(id: "", handle: "listener", displayName: "Listener")
    private static let entity = CatalogEntity.song(Song(id: "", name: "Song title", slug: "", artistId: ""))

    var body: some View {
        EntryCard(entry: Self.entry, author: Self.author, entity: Self.entity)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading recent writing")
            .accessibilityHidden(!announces)
    }
}

/// A quiet row in place of the feed when its first page can't load.
private struct NowFeedErrorRow: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: RN.Space.m) {
            Text("Recent writing didn't load.")
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RN.Palette.rustText)
        }
        .padding(RN.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
