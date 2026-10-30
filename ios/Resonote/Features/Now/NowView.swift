import ResonoteKit
import SwiftUI

/// The Now tab: what's playing and an invitation to write about it, unfinished
/// drafts, then the person's own recent listening and notes. Writing others published
/// is one row away (`Route.feed`), never the home screen.
struct NowView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(\.scenePhase) private var scenePhase

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
                NowOwnSections()
                NowFeedLink()
                    .padding(.top, RN.Space.s)
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
        // A note written first found its song.
        .onChange(of: model.writtenNotesAttached) { _, _ in draftReads += 1 }
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
        async let own: Void = model.refreshSession()
        _ = await (playing, own)
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
    /// A note written before its song was known: it opens in capture, to save it or
    /// change its song.
    let noteKey: String?
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
        noteKey = draft.isWrittenFirst ? draft.key : nil
        let fallbackName = draft.isWaitingForSong ? "Waiting for its song" : (title.isEmpty ? "\(draft.entityKind.label) draft" : title)
        name = entity?.name ?? draft.track?.title ?? fallbackName
        preview = firstLine.isEmpty ? (title.isEmpty ? "No words yet" : title) : firstLine
        artworkURL = entity.flatMap { catalog.artworkURL(for: $0) } ?? draft.track?.artworkURL
        let age = NowRelativeTime.phrase(since: draft.updatedAt, now: now)
        if draft.isWrittenFirst {
            if draft.isWaitingForSong {
                edited = "Written \(NowRelativeTime.phrase(since: draft.writtenAt ?? draft.updatedAt, now: now))"
            } else {
                edited = draft.attachment == .automatic ? "Attached automatically · change" : age
            }
        } else if draft.isUnmatched {
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
        if let noteKey = row.noteKey {
            router.present(.capture(CapturePreset(origin: "note", noteKey: noteKey)))
        } else if let track = row.unmatchedTrack {
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

// MARK: - Your listening and notes

/// The owner's newest logged listens and entries, derived once per data change.
private struct NowOwnDigest {
    struct Input: Equatable {
        var entries: [JournalEntry]
        var listens: [ListenLog]
        var ownerId: String
    }

    let listens: [ListenLog]
    let entries: [JournalEntry]
    let hasMoreEntries: Bool
    let refs: [CatalogRef]

    static let listenLimit = 5
    static let entryLimit = 3

    init(_ input: Input) {
        listens = Array(JournalOrder.listenDays(input.listens).flatMap(\.listens).prefix(Self.listenLimit))
        let own = JournalOrder.newestFirst(input.entries.filter { $0.profileId == input.ownerId || $0.profileId.isEmpty })
        entries = Array(own.prefix(Self.entryLimit))
        hasMoreEntries = own.count > Self.entryLimit
        refs = listens.map { CatalogRef(kind: .song, id: $0.songId) }
            + entries.map { CatalogRef(kind: $0.entityKind, id: $0.entityId) }
    }
}

/// "Your listening" and "Your notes". Signed out, one invitation stands in for both;
/// while the cached session is still being read, nothing shows, so nothing flashes.
private struct NowOwnSections: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var memo = JournalMemo<NowOwnDigest.Input, NowOwnDigest>()
    @State private var unavailable: Set<String> = []

    var body: some View {
        if let bundle = model.bundle {
            let digest = memo.value(for: NowOwnDigest.Input(entries: bundle.entries, listens: bundle.listens, ownerId: bundle.profile.id), NowOwnDigest.init)
            Group {
                listening(digest)
                notes(digest)
            }
            .loadsMissingCatalog(digest.refs, unavailable: $unavailable)
        } else if !model.isRestoringSession {
            EmptyStateView(
                title: "Your listening and notes live here",
                message: "Sign in to keep what you hear and what you write. Everything starts private.",
                actionTitle: "Continue with email",
                action: { model.requireAuth {} }
            )
            .padding(.top, RN.Space.l)
        }
    }

    @ViewBuilder
    private func listening(_ digest: NowOwnDigest) -> some View {
        SectionHeader(eyebrow: "Only you see this", title: "Your listening")
            .padding(.top, RN.Space.l)
        if digest.listens.isEmpty {
            NowQuietNote(text: "Listens you log appear here. Note what's playing above, or use Log listen on a song's page.")
        } else {
            VStack(spacing: 0) {
                ForEach(digest.listens) { listen in
                    NowListenRow(listen: listen, isUnavailable: unavailable.contains(listen.songId))
                    if listen.id != digest.listens.last?.id {
                        Divider().overlay(RN.Palette.line)
                    }
                }
            }
            .padding(.horizontal, RN.Space.l)
            .cardSurface()
        }
    }

    @ViewBuilder
    private func notes(_ digest: NowOwnDigest) -> some View {
        HStack(alignment: .lastTextBaseline) {
            SectionHeader(eyebrow: "Your writing", title: "Recent notes")
            if digest.hasMoreEntries {
                Button("See all") { router.tab = .journal }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RN.Palette.rustText)
                    .accessibilityHint("Opens your journal")
            }
        }
        .padding(.top, RN.Space.l)
        if digest.entries.isEmpty {
            NowQuietNote(text: "Nothing written yet. What you write stays private until you choose to publish it.")
        } else {
            ForEach(digest.entries) { entry in
                let entity = model.catalog.entity(kind: entry.entityKind, id: entry.entityId)
                EntryCard(
                    entry: entry,
                    author: nil,
                    entity: entity,
                    artworkURL: entity.flatMap { model.catalog.artworkURL(for: $0) },
                    onOpen: { router.push(.entry(id: entry.id)) }
                )
            }
        }
    }
}

/// One logged listen, compact: the song, its moods or note, and when.
private struct NowListenRow: View {
    let listen: ListenLog
    let isUnavailable: Bool

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
            CatalogRowPlaceholder(artworkSize: 40, isUnavailable: isUnavailable)
                .padding(.vertical, RN.Space.m)
        }
    }

    private func content(_ song: Song) -> some View {
        let entity = CatalogEntity.song(song)
        return HStack(spacing: RN.Space.m) {
            ArtworkView(model.catalog.artworkURL(for: entity), title: song.name, size: 40)
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

/// A muted line in a card where a section has nothing yet.
private struct NowQuietNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(RN.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(RN.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

// MARK: - Published by others

/// The way to the feed: a row the person chooses to open, below their own things.
private struct NowFeedLink: View {
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.push(.feed)
        } label: {
            HStack(spacing: RN.Space.m) {
                Image(systemName: "text.book.closed")
                    .font(.title3)
                    .foregroundStyle(RN.Palette.rustText)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Published by others")
                        .font(.body.weight(.medium))
                        .foregroundStyle(RN.Palette.ink)
                    Text("Read what people chose to publish, newest first.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(RN.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(RoundedRectangle(cornerRadius: RN.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
