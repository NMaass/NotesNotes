import ResonoteKit
import SwiftUI
import UIKit

/// Knows what the person is listening to, as well as iOS allows, and what it maps
/// to in Resonote's catalog.
///
/// Sources, sampled on demand rather than watched in the background:
/// 1. the Music app on this phone (real time, Apple Music only);
/// 2. Last.fm / ListenBrainz through the backend (covers Spotify and anything that scrobbles);
/// 3. Shazam, when the person asks it to listen;
/// 4. shared or pasted links, and tracks handed over by a Shortcut.
///
/// The card never blanks while a refresh runs: the last known track stays until a
/// different one replaces it. "Playing" is claimed only while a source vouches for it
/// (`isConfirmedPlaying`, the same rule the widget uses), and matching a track to the
/// catalog is owned here, so a caller going away never leaves a false failure behind.
@Observable
final class NowPlayingService {
    enum Phase: Equatable {
        /// Nothing sampled yet this launch.
        case idle
        case looking
        /// A track is known and being matched to the catalog.
        case resolving
        /// The track is matched to a catalog song.
        case ready
        /// A track is known but no catalog song was confidently matched.
        case unmatched
        /// No source reports anything.
        case nothing
    }

    private(set) var track: NowPlayingTrack?
    private(set) var resolution: ResolveResponse?
    private(set) var phase: Phase = .idle
    /// Whether a source vouches, right now, that `track` is playing. Drives the spinning
    /// record and every "playing" label in the app.
    private(set) var isConfirmedPlaying = false
    private(set) var isIdentifying = false
    /// Why the last identify attempt failed, for one quiet line under the button.
    private(set) var identifyFailure: SongRecognizer.Failure?
    /// The last song Shazam matched, for a surface that waited on another's identify.
    private(set) var lastIdentified: NowPlayingTrack?
    /// A music link is on the clipboard (detected without reading it).
    private(set) var copiedLinkAvailable = false
    private(set) var appleMusicAccess: AppleMusicSource.Access

    var linkedSources: LinkedSources {
        didSet {
            guard linkedSources != oldValue else { return }
            linkedSources.save()
            WidgetBridge.sourcesDidChange()
        }
    }

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let appleMusic = AppleMusicSource()
    @ObservationIgnored private let recognizer = SongRecognizer()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The one catalog match in progress, for the song it belongs to.
    @ObservationIgnored private var resolveTask: (identity: String, task: Task<Void, Never>)?
    /// Ends the playback claim when its window runs out.
    @ObservationIgnored private var claimTask: Task<Void, Never>?
    @ObservationIgnored private var lastSample: Date?
    /// When the person last identified, shared, or picked a song. Sampling doesn't replace it for a few minutes.
    @ObservationIgnored private var pickedAt: Date?
    /// Bumped only when the person picks a song (identify, a link, search, a Shortcut, a
    /// share): a link being read gives way to a newer pick, never to a background sample.
    @ObservationIgnored private var pick = 0
    @ObservationIgnored private var lastWidgetWrite: (identity: String, isPlaying: Bool, at: Date)?
    @ObservationIgnored private var hasActivated = false

    /// How long a song the person chose stays put while other sources report something else.
    private static let pickHold: TimeInterval = 3 * 60
    /// Activations and tab returns closer together than this reuse the last sample.
    private static let sampleFreshFor: TimeInterval = 20
    /// The same song still playing is written to the widget at most this often.
    private static let widgetRefreshInterval: TimeInterval = 4 * 60

    init(model: AppModel) {
        self.model = model
        linkedSources = LinkedSources.load()
        appleMusicAccess = appleMusic.access
        let snapshot = NowPlayingSnapshot.load()
        if let restored = snapshot.track, !restored.isStale() {
            track = restored
            resolution = snapshot.currentResolution
            phase = resolution?.song != nil ? .ready : .unmatched
            isConfirmedPlaying = restored.claimsPlayback()
        }
    }

    var song: Song? { resolution?.song }

    /// The song's own suggestions, topped up with this person's habits.
    var suggestions: TagSuggestions {
        let habits = model.habits
        return resolution?.suggestions.merged(withHabits: habits) ?? habits
    }

    // MARK: Lifecycle

    /// Call when the scene becomes active.
    func activate() {
        // The snapshot was read at launch; later activations pick up what an extension wrote meanwhile.
        if hasActivated { absorbSnapshot() }
        hasActivated = true
        dropIfStale()
        updateClaim()
        appleMusicAccess = appleMusic.access
        if linkedSources.appleMusicEnabled {
            appleMusic.startObserving { [weak self] in self?.scheduleRefresh(force: true) }
        }
        scheduleRefresh()
        detectCopiedLink()
    }

    /// Call when the scene leaves the foreground.
    func deactivate() {
        appleMusic.stopObserving()
        claimTask?.cancel()
    }

    /// Coalesces bursts of triggers (notifications, scene changes, tab returns) into one
    /// refresh. Without `force`, a sample taken moments ago is reused.
    func scheduleRefresh(force: Bool = false) {
        if !force, let lastSample, Date().timeIntervalSince(lastSample) < Self.sampleFreshFor { return }
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Samples every enabled source and adopts the best answer. The Music app answers
    /// at once, so its song is taken before waiting on the network. Matching starts here
    /// but isn't awaited; `resolveCurrent()` joins it.
    func refresh() async {
        lastSample = Date()
        if track == nil { phase = .looking }
        var answered: Set<NowPlayingTrack.Source> = []
        var candidates: [NowPlayingTrack] = []
        if linkedSources.appleMusicEnabled {
            switch NowPlayingRefresher.sampleAppleMusic() {
            case .track(let local):
                answered.insert(.appleMusic)
                candidates.append(local)
                if shouldTake(local) { take(local) }
            case .silent:
                answered.insert(.appleMusic)
            case .unavailable:
                break
            }
        }
        // Remote sources need the session; at launch it may still be being read from disk.
        await model.waitUntilRestored()
        if model.hasLiveSession, linkedSources.hasRemote,
           let response = try? await model.api.remoteNowPlaying(lastfm: linkedSources.lastfmUser, listenbrainz: linkedSources.listenbrainzUser, resolve: false) {
            answered.formUnion([.lastfm, .listenbrainz])
            if let remote = response.track { candidates.append(remote) }
        }
        guard !Task.isCancelled else { return }
        if let best = Self.best(of: candidates), shouldTake(best) {
            take(best)
        } else if let current = track, current.isPlaying, stopsClaiming(current, answered: answered) {
            // The source that reported playback no longer does, or a one-time report has had
            // its moment: keep the song, stop saying it plays.
            var stopped = current
            stopped.isPlaying = false
            setTrack(stopped)
            WidgetBridge.nowPlayingDidChange(track: stopped, resolution: resolution)
        } else if track == nil {
            phase = .nothing
        }
        dropIfStale()
    }

    /// Prefer what is actively playing, then the most recent report.
    static func best(of candidates: [NowPlayingTrack]) -> NowPlayingTrack? {
        candidates.max { a, b in
            if a.isPlaying != b.isPlaying { return !a.isPlaying }
            return (a.observedDate ?? .distantPast) < (b.observedDate ?? .distantPast)
        }
    }

    private func shouldTake(_ new: NowPlayingTrack) -> Bool {
        guard NowPlayingRefresher.shouldAdopt(new, over: track) else { return false }
        // A song the person identified, shared, or picked a moment ago stays, whatever plays meanwhile.
        if let pickedAt, Date().timeIntervalSince(pickedAt) < Self.pickHold, new.identity != track?.identity { return false }
        return true
    }

    private func stopsClaiming(_ current: NowPlayingTrack, answered: Set<NowPlayingTrack.Source>) -> Bool {
        if current.source.isLive { return answered.contains(current.source) }
        // A Shazam match or a Shortcut: the next refresh after the person's moment ends the claim.
        guard let pickedAt else { return true }
        return Date().timeIntervalSince(pickedAt) >= Self.pickHold
    }

    /// Makes a sampled track current and starts matching it if it's a different song.
    private func take(_ newTrack: NowPlayingTrack) {
        if makeCurrent(newTrack) { startResolving() }
    }

    // MARK: Inputs

    /// Makes `newTrack` current and matches it to the catalog if it is a different song.
    func adopt(_ newTrack: NowPlayingTrack) async {
        guard makeCurrent(newTrack) else { return }
        await resolveCurrent()
    }

    /// Makes a song handed over from outside (a Shortcut) current right away, so a
    /// sheet opened next already shows it, and matches it in the background.
    func present(_ newTrack: NowPlayingTrack) {
        pickedAt = Date()
        pick += 1
        if makeCurrent(newTrack) { startResolving() }
    }

    /// Swaps in `newTrack`; returns whether it still needs matching. The same report
    /// again, with only its time moved, changes nothing on screen, so it is taken only now
    /// and then (often enough to keep a live playback claim current).
    private func makeCurrent(_ newTrack: NowPlayingTrack) -> Bool {
        let sameSong = newTrack.identity == track?.identity
        if sameSong, let current = track, Self.onlyTimeMoved(from: current, to: newTrack) {
            return resolution == nil
        }
        setTrack(newTrack)
        if sameSong {
            if resolution != nil {
                phase = resolution?.song != nil ? .ready : .unmatched
                publishSameSong(newTrack)
                return false
            }
            // Still being matched (or never was): join or start that, without starting over.
            return true
        }
        resolveTask?.task.cancel()
        resolveTask = nil
        resolution = nil
        phase = .resolving
        recordWidgetWrite(newTrack)
        WidgetBridge.nowPlayingDidChange(track: newTrack, resolution: nil)
        return true
    }

    private static func onlyTimeMoved(from current: NowPlayingTrack, to new: NowPlayingTrack) -> Bool {
        var aligned = current
        aligned.observedAt = new.observedAt
        guard aligned == new, let then = current.observedDate, let now = new.observedDate else { return false }
        return now.timeIntervalSince(then) < widgetRefreshInterval
    }

    private func setTrack(_ newTrack: NowPlayingTrack?) {
        if track != newTrack { track = newTrack }
        updateClaim()
    }

    /// The same song reported again: the widget needs a fresh time only now and then, or when play state changes.
    private func publishSameSong(_ newTrack: NowPlayingTrack) {
        let now = Date()
        if let last = lastWidgetWrite, last.identity == newTrack.identity, last.isPlaying == newTrack.isPlaying,
           now.timeIntervalSince(last.at) < Self.widgetRefreshInterval { return }
        recordWidgetWrite(newTrack)
        WidgetBridge.nowPlayingDidChange(track: newTrack, resolution: resolution)
    }

    private func recordWidgetWrite(_ written: NowPlayingTrack) {
        lastWidgetWrite = (written.identity, written.isPlaying, Date())
    }

    /// Keeps `isConfirmedPlaying` true only while the current report vouches for playback,
    /// and wakes when that ends: a live source is sampled again then, anything else just stops.
    private func updateClaim() {
        let claims = track?.claimsPlayback() ?? false
        if claims != isConfirmedPlaying { isConfirmedPlaying = claims }
        claimTask?.cancel()
        claimTask = nil
        guard claims, let ends = track?.playbackClaimEnds else { return }
        claimTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, ends.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            if self.track?.source.isLive == true { self.scheduleRefresh(force: true) }
            self.updateClaim()
        }
    }

    /// A song from many hours ago is history, not "now": capture never starts on it.
    private func dropIfStale() {
        guard let current = track, current.isStale() else { return }
        resolveTask?.task.cancel()
        resolveTask = nil
        resolution = nil
        setTrack(nil)
        phase = .nothing
    }

    /// Picks up a song an extension (share sheet, widget refresh) made "now" while the app was away.
    private func absorbSnapshot() {
        let snapshot = NowPlayingSnapshot.load()
        guard let shared = snapshot.track, shared.identity != track?.identity, !shared.isStale(),
              (shared.observedDate ?? .distantPast) > (track?.observedDate ?? .distantPast) else { return }
        if !shared.source.isLive {
            // Shared from another app: the person's pick.
            pickedAt = shared.observedDate ?? Date()
            pick += 1
        }
        resolveTask?.task.cancel()
        resolveTask = nil
        setTrack(shared)
        if let resolution = snapshot.currentResolution {
            apply(resolution)
        } else {
            resolution = nil
            phase = .resolving
            startResolving()
        }
    }

    /// Matches the current track; requires a live session. The request belongs to the
    /// service: a caller that stops waiting (a sheet closing) doesn't stop it, and a
    /// second caller for the same song joins the first.
    func resolveCurrent() async {
        await model.waitUntilRestored()
        guard let current = track else { return }
        guard model.hasLiveSession else {
            phase = .unmatched
            return
        }
        let identity = current.identity
        if let running = resolveTask, running.identity == identity {
            await running.task.value
            return
        }
        resolveTask?.task.cancel()
        phase = .resolving
        let api = model.api
        let task = Task { [weak self] in
            do {
                let response = try await api.resolve(ResolveRequest(track: current))
                self?.finishResolving(identity, with: response)
            } catch is CancellationError {
                // Superseded by another song, which has its own request.
            } catch {
                self?.failResolving(identity)
            }
        }
        resolveTask = (identity, task)
        await task.value
    }

    private func startResolving() {
        Task { await resolveCurrent() }
    }

    private func finishResolving(_ identity: String, with response: ResolveResponse) {
        guard track?.identity == identity else { return }
        if resolveTask?.identity == identity { resolveTask = nil }
        apply(response)
    }

    private func failResolving(_ identity: String) {
        guard track?.identity == identity else { return }
        if resolveTask?.identity == identity { resolveTask = nil }
        settlePhase()
    }

    /// Listens with Shazam and makes the match current. Returns the song Shazam heard,
    /// whatever another source reports meanwhile.
    @discardableResult
    func identify() async -> NowPlayingTrack? {
        guard !isIdentifying else { return nil }
        isIdentifying = true
        identifyFailure = nil
        defer { isIdentifying = false }
        switch await recognizer.recognize() {
        case .success(let match):
            pickedAt = Date()
            pick += 1
            lastIdentified = match
            if makeCurrent(match) { startResolving() }
            return match
        case .failure(let failure):
            identifyFailure = failure
            return nil
        }
    }

    /// What reading a shared or pasted link came to.
    enum LinkOutcome: Equatable {
        /// The link's song, now current.
        case found(NowPlayingTrack)
        /// The person picked another song while the link was read; that choice stands.
        case superseded
        /// The session has ended; signing in again reads it.
        case needsSignIn
        /// Resonote couldn't be reached; the same link may work in a moment.
        case unreachable(String)
        /// The link names no song Resonote can find.
        case noSong
    }

    /// Resolves a shared or pasted Spotify / Apple Music / YouTube Music link and makes
    /// its song current. Only another pick by the person (identify, a link, search, a
    /// Shortcut, a share) supersedes it; songs sampled in the background meanwhile don't.
    @discardableResult
    func resolve(link: String) async -> LinkOutcome {
        await model.waitUntilRestored()
        guard model.hasLiveSession else { return .needsSignIn }
        pick += 1
        let started = pick
        do {
            var response = try await model.api.resolve(ResolveRequest(url: link))
            guard pick == started else { return .superseded }
            // Never show the link's song under the previous track's title.
            guard let described = response.track ?? Self.track(describing: response, link: link, catalog: model.catalog) else { return .noSong }
            response.track = described
            pickedAt = Date()
            _ = makeCurrent(described)
            resolveTask?.task.cancel()
            resolveTask = nil
            apply(response)
            return .found(described)
        } catch APIError.unauthorized {
            return .needsSignIn
        } catch let error as APIError where error.isTransient {
            return .unreachable(error.localizedDescription)
        } catch is CancellationError {
            return .unreachable(APIError.transport("").localizedDescription)
        } catch {
            return .noSong
        }
    }

    /// A track for a link the backend matched to a song without describing it.
    private static func track(describing response: ResolveResponse, link: String, catalog: CatalogIndex) -> NowPlayingTrack? {
        guard let song = response.song else { return nil }
        let artist = response.artist ?? catalog.artists[song.artistId]
        let album = response.album ?? song.albumId.flatMap { catalog.albums[$0] }
        return NowPlayingTrack(title: song.name, artist: artist?.name ?? "", album: album?.name, durationMs: song.durationMs, artworkURL: album?.imageUrl ?? song.imageUrl, mbid: song.musicbrainzId, url: link, source: .link, isPlaying: false)
    }

    /// After a failed request: keep a match that is already held.
    private func settlePhase() {
        phase = resolution?.song != nil ? .ready : (track == nil ? .nothing : .unmatched)
    }

    /// Imports a MusicBrainz candidate the person picked for a weak match.
    func choose(_ candidate: SearchResult) async {
        guard case .song(let candidateSong) = candidate.entity, let mbid = candidateSong.musicbrainzId, var current = resolution else { return }
        let chosenFor = track?.identity
        phase = .resolving
        do {
            let slice = try await model.api.importFromMusicBrainz(kind: .song, mbid: mbid)
            model.absorb(slice)
            // The track may have changed while importing; the pick belongs to the old one.
            guard track?.identity == chosenFor else { return }
            guard let song = slice.songs.first(where: { $0.musicbrainzId == mbid }) ?? slice.songs.first else {
                phase = .unmatched
                return
            }
            current.song = song
            current.album = song.albumId.flatMap { id in slice.albums.first { $0.id == id } }
            current.artist = slice.artists.first { $0.id == song.artistId }
            current.confidence = .strong
            current.candidates = []
            apply(current)
        } catch {
            guard track?.identity == chosenFor else { return }
            settlePhase()
        }
    }

    /// Notes a song chosen by hand (search, a song page) as "now". Needs nothing from the
    /// network: the byline fills in when the catalog learns the artist.
    func use(song: Song) {
        let artist = model.catalog.artists[song.artistId]?.name ?? ""
        let album = model.catalog.album(for: song)
        let manual = NowPlayingTrack(title: song.name, artist: artist, album: album?.name, durationMs: song.durationMs, artworkURL: album?.imageUrl, mbid: song.musicbrainzId, source: .manual, isPlaying: false)
        pickedAt = Date()
        pick += 1
        _ = makeCurrent(manual)
        resolveTask?.task.cancel()
        resolveTask = nil
        apply(ResolveResponse(track: manual, song: song, album: album, artist: model.catalog.artists[song.artistId], confidence: .exact, suggestions: model.habits, entriesCount: 0))
    }

    func requestAppleMusicAccess() async {
        appleMusicAccess = await appleMusic.requestAccess()
        linkedSources.appleMusicEnabled = appleMusicAccess == .granted
        if appleMusicAccess == .granted { activate() }
    }

    func disableAppleMusic() {
        linkedSources.appleMusicEnabled = false
        appleMusic.stopObserving()
    }

    /// Checks for a copied web URL without reading the clipboard (no paste prompt).
    func detectCopiedLink() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasURLs || pasteboard.hasStrings else {
            if copiedLinkAvailable { copiedLinkAvailable = false }
            return
        }
        Task {
            let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL])
            let found = patterns?.contains(\.probableWebURL) ?? false
            if copiedLinkAvailable != found { copiedLinkAvailable = found }
        }
    }

    func dismissCopiedLink() {
        copiedLinkAvailable = false
    }

    // MARK: Internals

    private func apply(_ response: ResolveResponse) {
        var response = response
        if response.track == nil { response.track = track }
        resolution = response
        if let artist = response.artist { model.absorb(.artist(artist)) }
        if let album = response.album { model.absorb(.album(album)) }
        if let song = response.song {
            model.absorb(.song(song))
            // Words kept while this song was unmatched now belong to its draft.
            if let current = track { model.drafts.attachUnmatched(current, toSong: song.id) }
        }
        phase = response.song != nil ? .ready : .unmatched
        if let current = track { recordWidgetWrite(current) }
        WidgetBridge.nowPlayingDidChange(track: track, resolution: response)
    }
}

extension TagSuggestions {
    /// A song's own suggestions topped up with the person's habits: at most four
    /// lenses and four moods, the song's first.
    func merged(withHabits habits: TagSuggestions) -> TagSuggestions {
        var seenLenses = Set<MusicLens>()
        var seenMoods = Set<String>()
        return TagSuggestions(
            genres: genres,
            lenses: Array((lenses + habits.lenses).filter { seenLenses.insert($0).inserted }.prefix(4)),
            moods: Array((moods + habits.moods).filter { seenMoods.insert($0).inserted }.prefix(4)),
            prompt: prompt
        )
    }
}
