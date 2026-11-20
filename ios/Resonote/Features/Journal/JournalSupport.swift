import ResonoteKit
import SwiftUI

// Pure helpers and small infrastructure shared by the Journal, profile, and
// collection screens, plus the Journal draft rows.

/// A catalog row a screen needs, by kind and id. `kind` is nil when only the id is
/// known (a pinned entity); the row is then looked up as a song, album, or artist.
nonisolated struct CatalogRef: Hashable, Sendable {
    let kind: EntityKind?
    let id: String
}

/// Recomputes a derived value only when its input changes, so view bodies stay
/// cheap (date parsing and grouping run once per data change, not once per render).
/// Hold it in `@State`; it is deliberately not observable.
final class JournalMemo<Input: Equatable, Output> {
    private var input: Input?
    private var output: Output?

    func value(for input: Input, _ compute: (Input) -> Output) -> Output {
        if let output, self.input == input { return output }
        let fresh = compute(input)
        self.input = input
        output = fresh
        return fresh
    }
}

enum JournalCopy {
    /// "1 item", "3 items".
    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    /// "01", "02" … "10", like the web's collection numbering.
    static func ordinal(_ index: Int) -> String {
        index < 9 ? "0\(index + 1)" : "\(index + 1)"
    }
}

enum ProfileHandle {
    /// "@Ana " → "ana", matching how the server looks handles up.
    static func normalize(_ handle: String) -> String {
        var value = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        return value.lowercased()
    }
}

/// One day of the private listening log.
struct ListenDay: Identifiable, Equatable {
    let id: String
    let title: String
    let listens: [ListenLog]
}

enum JournalOrder {
    /// Entries newest first by their last edit, as on the web profile.
    static func newestFirst(_ entries: [JournalEntry]) -> [JournalEntry] {
        entries
            .map { ($0, ResonoteDate.parse($0.updatedAt) ?? ResonoteDate.parse($0.createdAt) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Listens grouped by calendar day, newest day first, newest listen first within a day.
    static func listenDays(_ listens: [ListenLog], now: Date = Date(), calendar: Calendar = .current) -> [ListenDay] {
        let dated = listens
            .map { ($0, ResonoteDate.parse($0.listenedAt) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var days: [ListenDay] = []
        var currentDay: Date?
        var bucket: [ListenLog] = []
        func flush() {
            guard let day = currentDay, !bucket.isEmpty else { return }
            days.append(ListenDay(id: String(Int(day.timeIntervalSince1970)), title: title(for: day, now: now, calendar: calendar), listens: bucket))
        }
        for (listen, date) in dated {
            let day = calendar.startOfDay(for: date)
            if day != currentDay {
                flush()
                currentDay = day
                bucket = []
            }
            bucket.append(listen)
        }
        flush()
        return days
    }

    private static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if day == .distantPast { return "Earlier" }
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

/// Public profiles loaded recently, so returning to one never shows a placeholder or
/// downloads it again while it is fresh; a refresh replaces the bundle in place. Holds
/// the most recently used few.
enum PublicProfileCache {
    private struct Entry {
        var bundle: ProfileBundle
        var loadedAt: Date
    }

    private static var entries: [String: Entry] = [:]
    private static var order: [String] = []
    private static let capacity = 12
    /// Recent enough to skip the network when a page reappears.
    static let freshFor: TimeInterval = 90

    static func bundle(handle: String) -> ProfileBundle? {
        entries[ProfileHandle.normalize(handle)]?.bundle
    }

    static func isFresh(handle: String, now: Date = Date()) -> Bool {
        guard let entry = entries[ProfileHandle.normalize(handle)] else { return false }
        return now.timeIntervalSince(entry.loadedAt) < freshFor
    }

    static func store(_ bundle: ProfileBundle) {
        let key = ProfileHandle.normalize(bundle.profile.handle)
        entries[key] = Entry(bundle: bundle, loadedAt: Date())
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            entries[order.removeFirst()] = nil
        }
    }
}

extension AppModel {
    /// The signed-in handle, normalized, or nil when signed out.
    var ownHandle: String? {
        profile.map { ProfileHandle.normalize($0.handle) }
    }

    func isOwnHandle(_ handle: String) -> Bool {
        ownHandle == ProfileHandle.normalize(handle)
    }

    /// Loads someone's public page and records what it references, so entries
    /// and music on it render and open without another request. Without `force`, a
    /// copy loaded in the last minute or so is used as is.
    func loadPublicBundle(handle: String, force: Bool = true) async throws -> ProfileBundle {
        if !force, PublicProfileCache.isFresh(handle: handle), let cached = PublicProfileCache.bundle(handle: handle) {
            return cached
        }
        let bundle = try await api.profile(handle: ProfileHandle.normalize(handle))
        absorb(bundle.catalog)
        remember(entries: bundle.entries, profiles: [bundle.profile])
        PublicProfileCache.store(bundle)
        return bundle
    }

    /// Every catalog row a profile page can show, for `loadsMissingCatalog`. Bundles
    /// ship the rows they reference (seeded rows included); this only fills gaps.
    static func catalogRefs(for bundle: ProfileBundle) -> [CatalogRef] {
        var refs: [CatalogRef] = []
        if let songId = bundle.profile.profileSongId { refs.append(CatalogRef(kind: .song, id: songId)) }
        refs += bundle.entries.map { CatalogRef(kind: $0.entityKind, id: $0.entityId) }
        refs += bundle.likes.filter { $0.entityKind != .genre }.map { CatalogRef(kind: $0.entityKind, id: $0.entityId) }
        refs += bundle.listens.prefix(60).map { CatalogRef(kind: .song, id: $0.songId) }
        refs += bundle.collections.flatMap { $0.items.prefix(4) }.map { CatalogRef(kind: $0.entityKind, id: $0.entityId) }
        refs += bundle.profile.genreIds.map { CatalogRef(kind: .genre, id: $0) }
        // Pinned music: a pin records only the id, so the row is looked up by id.
        refs += bundle.pins.filter { $0.targetType == .entity }.map { CatalogRef(kind: nil, id: $0.targetId) }
        return refs
    }
}

// MARK: - Missing catalog rows

extension View {
    /// A fallback for catalog rows this device still lacks after the bundle's own
    /// catalog slice (which includes seeded rows) was absorbed: fetches them a few at a
    /// time so rows that reference them can fill in. Ids that cannot be loaded are added
    /// to `unavailable` so their rows stop showing a placeholder.
    func loadsMissingCatalog(_ refs: [CatalogRef], unavailable: Binding<Set<String>>) -> some View {
        modifier(MissingCatalogLoader(refs: refs, unavailable: unavailable))
    }
}

private struct MissingCatalogLoader: ViewModifier {
    @Environment(AppModel.self) private var model
    let refs: [CatalogRef]
    @Binding var unavailable: Set<String>

    private static let maxPerPass = 60
    private static let concurrency = 4
    private static let flushEvery = 8

    func body(content: Content) -> some View {
        content.task(id: refs) { await loadMissing() }
    }

    private func loadMissing() async {
        var seen = Set<String>()
        let missing = refs.filter { ref in
            guard seen.insert(ref.id).inserted, !unavailable.contains(ref.id) else { return false }
            guard let kind = ref.kind else { return model.catalog.entity(id: ref.id) == nil }
            if kind == .genre { return model.catalog.genres[ref.id] == nil }
            return model.catalog.entity(kind: kind, id: ref.id) == nil
        }
        guard !missing.isEmpty else { return }

        if missing.contains(where: { $0.kind == .genre }) {
            await loadGenres(missing.filter { $0.kind == .genre })
        }
        let entities = Array(missing.filter { $0.kind != .genre }.prefix(Self.maxPerPass))
        guard !entities.isEmpty, !Task.isCancelled else { return }

        let api = model.api
        var pending = CatalogSlice()
        var failed = Set<String>()
        await withTaskGroup(of: (CatalogRef, EntityDetail?).self) { group in
            var queue = entities.makeIterator()
            func enqueueNext() {
                guard let ref = queue.next() else { return }
                group.addTask { (ref, await Self.detail(for: ref, api: api)) }
            }
            for _ in 0..<Self.concurrency { enqueueNext() }
            var received = 0
            while let result = await group.next() {
                if Task.isCancelled { break }
                let (ref, detail) = result
                if let detail {
                    Self.add(detail, to: &pending)
                } else {
                    failed.insert(ref.id)
                }
                received += 1
                if received.isMultiple(of: Self.flushEvery) {
                    model.absorb(pending)
                    pending = CatalogSlice()
                }
                enqueueNext()
            }
        }
        guard !Task.isCancelled else { return }
        model.absorb(pending)
        if !failed.isEmpty { unavailable.formUnion(failed) }
    }

    /// The page for `ref`; with no kind, the kinds a pin can point at are tried in turn.
    private nonisolated static func detail(for ref: CatalogRef, api: APIClient) async -> EntityDetail? {
        if let kind = ref.kind { return try? await api.entity(kind: kind, id: ref.id) }
        for kind in [EntityKind.song, .album, .artist] {
            if let detail = try? await api.entity(kind: kind, id: ref.id) { return detail }
        }
        return nil
    }

    /// Genres missing from a bundle (older servers left seeded ones out); one request brings every genre.
    private func loadGenres(_ refs: [CatalogRef]) async {
        guard let genres = try? await model.api.genres(), !Task.isCancelled else { return }
        model.absorb(CatalogSlice(genres: genres))
        let known = Set(genres.map(\.id))
        let failed = refs.map(\.id).filter { !known.contains($0) }
        if !failed.isEmpty { unavailable.formUnion(failed) }
    }

    private static func add(_ detail: EntityDetail, to slice: inout CatalogSlice) {
        switch detail.entity {
        case .artist(let artist): slice.artists.append(artist)
        case .album(let album): slice.albums.append(album)
        case .song(let song): slice.songs.append(song)
        case .genre(let genre): slice.genres.append(genre)
        }
        if let artist = detail.artist { slice.artists.append(artist) }
        if let album = detail.album { slice.albums.append(album) }
    }
}

// MARK: - Small shared views

/// A row-shaped stand-in with the final geometry of an entity row, shown while a
/// catalog row loads, or a quiet "unavailable" line once it cannot be loaded.
struct CatalogRowPlaceholder: View {
    var artworkSize: CGFloat = 46
    var isUnavailable = false

    var body: some View {
        HStack(spacing: RN.Space.m) {
            RoundedRectangle(cornerRadius: RN.Radius.artwork)
                .fill(RN.Palette.paper3)
                .frame(width: artworkSize, height: artworkSize)
            VStack(alignment: .leading, spacing: 2) {
                if isUnavailable {
                    Text("Not available right now")
                        .font(.body)
                        .foregroundStyle(RN.Palette.muted)
                    Text("Resonote couldn't load this piece of music.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                } else {
                    Text("Loading music title")
                        .font(.body.weight(.medium))
                    Text("Artist name")
                        .font(.subheadline)
                }
            }
            .lineLimit(1)
            .redacted(reason: isUnavailable ? [] : .placeholder)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isUnavailable ? "Music not available right now" : "Loading")
    }
}

/// A small outlined tag, like the lens tags on an entry card.
struct JournalTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(RN.Palette.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(RN.Palette.line))
    }
}

// MARK: - Drafts

/// Unfinished drafts at the top of Journal: plain rows that read and reload themselves
/// whenever a sheet closes, the app returns, or the signed-in person changes.
struct JournalDraftsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var drafts: [NowDraftRow] = []
    @State private var hasReadDrafts = false
    @State private var draftReads = 0

    private static let draftLimit = 5

    var body: some View {
        Group {
            if !drafts.isEmpty {
                NowDraftsList(drafts: drafts)
            }
        }
        .onAppear {
            if hasReadDrafts {
                draftReads += 1
            } else {
                // The first read is inline (a few small files), so the rows are there with the first frame.
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

private struct NowDraftsList: View {
    let drafts: [NowDraftRow]

    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying

    var body: some View {
        VStack(spacing: 0) {
            ForEach(drafts) { row in
                Button {
                    open(row)
                } label: {
                    NowDraftRowView(row: row)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the draft")
                Divider()
                    .overlay(RN.Palette.line)
                    .padding(.leading, JournalRow.textInset)
            }
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
            ArtworkView(row.artworkURL, title: row.name, size: JournalRow.artSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text("\(row.edited) · \(row.preview)")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: RN.Space.s)
            Text("Draft")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RN.Palette.rustText)
        }
        .padding(.vertical, RN.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
