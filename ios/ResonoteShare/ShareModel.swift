import Foundation
import Observation
import ResonoteKit
import WidgetKit

/// The share sheet's state: resolve the shared link to a catalog song, then save a
/// note, a listen, and genre tags straight to the backend. A share extension can't
/// open the app, so it does the whole job itself.
///
/// The person's writing is never dropped: a failed save keeps the sheet with Retry,
/// and cancelling with text offers to keep it as a draft the app's composer picks up
/// (or, for a song not matched yet, a draft that joins the song once the app matches it).
/// A retry sends only what the server hasn't confirmed, so nothing is written twice.
@Observable
final class ShareModel {
    enum Phase: Equatable {
        /// Reading the attachment and resolving it.
        case loading
        case signedOut
        /// The shared item has no web link.
        case noLink
        /// The backend couldn't be reached; the message says why.
        case unreachable(String)
        /// Resolved, but no catalog song was confidently matched.
        case unmatched
        case ready
    }

    enum SaveKind: Equatable {
        case note, listen, tags, nothing

        var label: String {
            switch self {
            case .note, .nothing: "Save note"
            case .listen: "Log listen"
            case .tags: "Save tags"
            }
        }
    }

    static let saveLabels = ["Save note", "Log listen", "Save tags", "Saving…", "Saved"]

    private(set) var phase: Phase = .loading
    private(set) var resolution: ResolveResponse?
    /// The candidate being imported after the person picked it.
    private(set) var importingCandidateId: String?
    private(set) var candidateError: String?

    var text = ""
    var lenses: [MusicLens] = []
    var moods: [String] = []
    var genreIds: [String] = []
    var isPublic = false

    private(set) var isSaving = false
    private(set) var didSave = false
    private(set) var saveError: String?

    @ObservationIgnored var onFinish: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}

    @ObservationIgnored private let api: APIClient?
    @ObservationIgnored private var link: String?
    // Stable per sheet, so a retry updates the same entry instead of adding another.
    @ObservationIgnored private let entryId = Identifiers.make()
    @ObservationIgnored private let listenId = Identifiers.make()
    @ObservationIgnored private var entryCreatedAt: String?
    // What the server already confirmed, so a retry sends only the rest.
    /// The note text the server holds as this sheet's entry.
    private(set) var confirmedEntryText: String?
    @ObservationIgnored private var listenConfirmed = false
    @ObservationIgnored private var confirmedGenreIds: Set<String> = []

    init(token: String? = TokenStore.shared.read()) {
        api = token.map { token in APIClient(baseURL: AppGroup.apiBaseURL, token: { token }) }
    }

    // MARK: Derived

    var song: Song? { resolution?.song }

    var title: String? {
        song?.name ?? resolution?.track?.title
    }

    var artist: String? {
        resolution?.artist?.name ?? resolution?.track?.artist
    }

    var artworkURL: String? {
        [resolution?.track?.artworkURL, song?.imageUrl, resolution?.album?.imageUrl]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }

    var prompt: String {
        resolution?.suggestions.prompt ?? Vocabulary.prompts[1]
    }

    var candidates: [SearchResult] {
        resolution?.candidates ?? []
    }

    /// Every lens, the song's suggestions first.
    var lensOptions: [MusicLens] {
        let suggested = resolution?.suggestions.lenses ?? []
        return suggested + MusicLens.allCases.filter { !suggested.contains($0) }
    }

    /// Every listen mood, the person's and the song's suggestions first.
    var moodOptions: [String] {
        let suggested = resolution?.suggestions.moods ?? []
        var seen = Set<String>()
        return (suggested + Vocabulary.moods).filter { seen.insert($0).inserted }
    }

    var genreOptions: [GenreSuggestion] {
        resolution?.suggestions.genres ?? []
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var saveKind: SaveKind {
        if !trimmedText.isEmpty { return .note }
        if !moods.isEmpty { return .listen }
        if !genreIds.isEmpty { return .tags }
        return .nothing
    }

    var saveLabel: String {
        if didSave { return "Saved" }
        if isSaving { return "Saving…" }
        return saveKind.label
    }

    var canSave: Bool {
        phase == .ready && saveKind != .nothing && !isSaving && !didSave
    }

    /// Text that would be lost if the sheet went away now. Words already published as
    /// this sheet's entry are not at risk, even if a later part of the save failed.
    var hasUnsavedWork: Bool {
        !trimmedText.isEmpty && !didSave && trimmedText != confirmedEntryText
    }

    /// Whether the words can be kept as a draft: a matched song, or a track to match later.
    var canKeepDraft: Bool {
        song != nil || resolution?.track != nil
    }

    // MARK: Resolving

    func start(link: String?) async {
        guard api != nil else {
            phase = .signedOut
            return
        }
        guard let link else {
            phase = .noLink
            return
        }
        self.link = link
        await resolve()
    }

    func resolve() async {
        guard let api, let link else { return }
        phase = .loading
        do {
            let response = try await api.resolve(ResolveRequest(url: link))
            resolution = response
            phase = response.song != nil ? .ready : .unmatched
            publish(response)
        } catch is CancellationError {
            return
        } catch APIError.unauthorized {
            phase = .signedOut
        } catch {
            phase = .unreachable(Self.message(for: error))
        }
    }

    /// Imports the MusicBrainz recording the person picked for a weak match.
    func choose(_ candidate: SearchResult) async {
        guard let api, importingCandidateId == nil, var current = resolution,
              case .song(let picked) = candidate.entity, let mbid = picked.musicbrainzId else { return }
        importingCandidateId = candidate.id
        candidateError = nil
        defer { importingCandidateId = nil }
        do {
            let slice = try await api.importFromMusicBrainz(kind: .song, mbid: mbid)
            guard let song = slice.songs.first(where: { $0.musicbrainzId == mbid }) ?? slice.songs.first else {
                candidateError = "That one couldn’t be added. Try another."
                return
            }
            current.song = song
            current.album = song.albumId.flatMap { id in slice.albums.first { $0.id == id } }
            current.artist = slice.artists.first { $0.id == song.artistId }
            current.confidence = .strong
            current.candidates = []
            resolution = current
            phase = .ready
            publish(current)
        } catch {
            candidateError = Self.message(for: error)
        }
    }

    // MARK: Choosing

    func toggle(_ lens: MusicLens) {
        if let index = lenses.firstIndex(of: lens) { lenses.remove(at: index) } else { lenses.append(lens) }
    }

    func toggle(mood: String) {
        if let index = moods.firstIndex(of: mood) { moods.remove(at: index) } else { moods.append(mood) }
    }

    func toggle(genreId: String) {
        if let index = genreIds.firstIndex(of: genreId) { genreIds.remove(at: index) } else { genreIds.append(genreId) }
    }

    // MARK: Saving

    /// Sends the note, the listen, and the genre tags; stops at the first failure and keeps everything.
    func save() async {
        guard canSave, let api, let song else { return }
        isSaving = true
        saveError = nil
        let now = ResonoteDate.now()
        let note = trimmedText

        var operations: [SyncOperation] = []
        if !note.isEmpty, note != confirmedEntryText {
            let createdAt = entryCreatedAt ?? now
            entryCreatedAt = createdAt
            let document = RichDocument.plain(note)
            operations.append(.entry(JournalEntry(
                id: entryId, profileId: "", entityId: song.id, entityKind: .song,
                document: document, plainText: document.plainText, lenses: lenses,
                isPublic: isPublic, createdAt: createdAt, updatedAt: now
            )))
        }
        if !moods.isEmpty, !listenConfirmed {
            operations.append(.listen(ListenLog(id: listenId, profileId: "", songId: song.id, moods: moods, listenedAt: now)))
        }
        // Tags the person already holds for this song (as the app last saw) or that this sheet already sent are skipped.
        let held = Self.assertedGenres(on: song.id).union(confirmedGenreIds)
        for genreId in genreIds where !held.contains(genreId) {
            operations.append(.genreAssertion(entityId: song.id, entityKind: .song, genreId: genreId, asserted: true))
        }

        do {
            for operation in operations {
                try await api.sync(operation)
                // The app reads its journal again when it next comes forward, so this shows up there.
                ExternalWrites.mark()
                switch operation {
                case .entry: confirmedEntryText = note
                case .listen: listenConfirmed = true
                case .genreAssertion(_, _, let genreId, _): confirmedGenreIds.insert(genreId)
                default: break
                }
            }
        } catch {
            isSaving = false
            saveError = Self.message(for: error)
            return
        }

        isSaving = false
        didSave = true
        recordSaved(songId: song.id, wroteNote: !note.isEmpty)
        try? await Task.sleep(for: .milliseconds(700))
        onFinish()
    }

    /// Keeps the note as a draft for the app's composer, adding to any draft already
    /// there. A song not matched yet keeps it with the track until the app matches it.
    /// The draft belongs to the person signed in to the app, so nobody else sees it.
    func keepDraft() {
        guard hasUnsavedWork else { return }
        let drafts = DraftStore.shared.scoped(to: Self.signedInProfileId())
        if let song {
            drafts.append(trimmedText, lenses: lenses, isPublic: isPublic, kind: .song, entityId: song.id)
        } else if let track = resolution?.track {
            drafts.appendUnmatched(trimmedText, lenses: lenses, isPublic: isPublic, track: track)
        }
    }

    /// The profile the app's cached session belongs to.
    private static func signedInProfileId() -> String? {
        SharedFile.read(CachedOwner.self, from: "bundle.json")?.profile.id
    }

    /// The genre tags the signed-in person holds on `songId`, from the bundle the app cached.
    private static func assertedGenres(on songId: String) -> Set<String> {
        guard let bundle = SharedFile.read(ProfileBundle.self, from: "bundle.json") else { return [] }
        return Set(bundle.genreAssertions.filter { $0.entityId == songId }.map(\.genreId))
    }

    // MARK: Shared state

    /// Makes the shared song "now" for the widget and the app.
    private func publish(_ response: ResolveResponse) {
        let described = response.track ?? song.map { song in
            NowPlayingTrack(title: song.name, artist: response.artist?.name ?? "", source: .link, isPlaying: false)
        }
        guard var track = described else { return }
        track.source = .link
        track.isPlaying = false
        track.observedAt = ResonoteDate.now()
        if track.artworkURL == nil { track.artworkURL = artworkURL }
        var resolution = response
        resolution.track = track

        var snapshot = NowPlayingSnapshot.load()
        snapshot.track = track
        snapshot.resolution = resolution
        snapshot.updatedAt = ResonoteDate.now()
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func recordSaved(songId: String, wroteNote: Bool) {
        guard wroteNote else { return }
        var snapshot = NowPlayingSnapshot.load()
        snapshot.recentlyNotedSongIds = Array(([songId] + snapshot.recentlyNotedSongIds.filter { $0 != songId }).prefix(30))
        snapshot.updatedAt = ResonoteDate.now()
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Just the owner's id out of the app's cached bundle.
    private struct CachedOwner: Decodable {
        struct Owner: Decodable { var id: String }
        var profile: Owner
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case APIError.unauthorized:
            "Your session ended. Open Resonote and sign in again."
        case let error as APIError:
            error.errorDescription ?? "Something went wrong. Try again."
        default:
            "Resonote can’t be reached right now."
        }
    }
}
