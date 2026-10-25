import Foundation
import MediaPlayer
import ResonoteKit

/// Refreshes the shared now-playing snapshot from outside the app: the widget's
/// timeline provider and its refresh button both use it.
///
/// It samples what an extension can reach — the Music app (when the person turned it
/// on and granted access) and their linked Last.fm / ListenBrainz accounts through the
/// backend — keeps the snapshot's other fields, and never throws: a failed or slow
/// network leaves the last known song in place.
nonisolated enum NowPlayingRefresher {
    /// Samples, resolves, and saves within `budget`. Returns the snapshot to show.
    static func refresh(budget: Duration) async -> NowPlayingSnapshot {
        let deadline = ContinuousClock.now.advanced(by: budget)
        let before = NowPlayingSnapshot.load()
        let sources = LinkedSources.load()
        let api = TokenStore.shared.read().map { token in
            APIClient(baseURL: AppGroup.apiBaseURL, token: { token })
        }

        var candidates: [Candidate] = []
        /// Sources that answered this time, with or without a track.
        var answered: Set<NowPlayingTrack.Source> = []

        if sources.appleMusicEnabled {
            switch await sampleAppleMusic() {
            case .track(let track):
                candidates.append(Candidate(track: track, resolution: nil))
                answered.insert(.appleMusic)
            case .silent:
                answered.insert(.appleMusic)
            case .unavailable:
                break
            }
        }

        if let api, sources.hasRemote {
            // Only the scrobble lookup (well under a second). Matching a song Resonote hasn't
            // seen can take longer than the whole budget, and must never cost the new track:
            // it runs next, with whatever time is left.
            let response = await within(deadline) {
                try await api.remoteNowPlaying(lastfm: sources.lastfmUser, listenbrainz: sources.listenbrainzUser, resolve: false)
            }
            if let response {
                answered.formUnion([.lastfm, .listenbrainz])
                if let track = response.track {
                    candidates.append(Candidate(track: track, resolution: response.resolution))
                }
            }
        }

        // A live source that answered without the current song no longer plays it, and a
        // one-time report (Shazam, a Shortcut) stops claiming playback on the next refresh.
        var track = before.track
        var resolution = before.resolution
        if var stale = track, stale.isPlaying, answered.contains(stale.source) || !stale.source.isLive {
            stale.isPlaying = false
            track = stale
        }

        if let best = best(of: candidates), shouldAdopt(best.track, over: track) {
            let sameSong = best.track.identity == track?.identity
            track = best.track
            // Out of time: the new song shows without its match (the widget falls back to
            // the person's habits) rather than the old song staying.
            let found = await self.resolution(for: best, keeping: resolution, api: api, deadline: deadline)
            if let found {
                resolution = found
            } else if !sameSong {
                resolution = nil
            }
        }

        // The app or the share sheet may have written while the network ran: keep
        // their fields, and if they changed the song, theirs is newer.
        var snapshot = NowPlayingSnapshot.load()
        guard snapshot.track == before.track else { return snapshot }
        let unchanged = snapshot
        snapshot.track = track
        snapshot.resolution = resolution
        guard snapshot != unchanged else { return unchanged }
        snapshot.updatedAt = ResonoteDate.now()
        snapshot.save()
        return snapshot
    }

    /// Whether `snapshot` was written recently enough that sampling again would only repeat it.
    static func isFresh(_ snapshot: NowPlayingSnapshot, within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard let updated = ResonoteDate.parse(snapshot.updatedAt) else { return false }
        return now.timeIntervalSince(updated) < interval
    }

    /// Sources that report playback as it happens, as opposed to a one-time match or a pick.
    static func isLive(_ source: NowPlayingTrack.Source) -> Bool {
        source.isLive
    }

    // MARK: Choosing

    private struct Candidate: Sendable {
        var track: NowPlayingTrack
        var resolution: ResolveResponse?
    }

    /// Prefer what is actively playing, then the most recent report.
    private static func best(of candidates: [Candidate]) -> Candidate? {
        candidates.max { a, b in
            if a.track.isPlaying != b.track.isPlaying { return !a.track.isPlaying }
            return (a.track.observedDate ?? .distantPast) < (b.track.observedDate ?? .distantPast)
        }
    }

    /// A sampled track replaces the current one when it is the same song (fresher
    /// state), when it is playing, or when both are "last played" reports and it is
    /// newer. A paused Music app item never displaces a song identified or shared since.
    /// The app's `NowPlayingService` can apply the same rule to its own samples.
    static func shouldAdopt(_ new: NowPlayingTrack, over current: NowPlayingTrack?, at now: Date = Date()) -> Bool {
        guard let current else { return true }
        if new.identity == current.identity || new.isPlaying { return true }
        // Something still playing (a live source, or a recent Shazam match) isn't displaced by a "last played" report.
        guard !current.claimsPlayback(at: now) else { return false }
        if !isLive(current.source) {
            // A song identified, shared, or picked stays until something plays, unless it's old.
            return current.isStale(at: now)
        }
        return (new.observedDate ?? .distantPast) > (current.observedDate ?? .distantPast)
    }

    /// The catalog match for `candidate`: one that came with it, the one already held
    /// for the same song, or a resolve within what's left of the budget. Its `track` is
    /// aligned with the snapshot's so the pair matches.
    private static func resolution(for candidate: Candidate, keeping existing: ResolveResponse?, api: APIClient?, deadline: ContinuousClock.Instant) async -> ResolveResponse? {
        let track = candidate.track
        var found = candidate.resolution
        if found == nil, let existing, existing.track?.identity == track.identity {
            found = existing
        }
        if found == nil, let api {
            found = await within(deadline) { try await api.resolve(ResolveRequest(track: track)) }
        }
        found?.track = track
        return found
    }

    // MARK: Music app

    enum AppleMusicSample: Sendable {
        case track(NowPlayingTrack)
        /// Access is granted and the Music app has nothing playing or paused.
        case silent
        /// No access; nothing can be said about the Music app.
        case unavailable
    }

    /// What the Music app has playing or paused. Shared by the app's `AppleMusicSource`
    /// and the widget, so both describe the Music app the same way. MediaPlayer's
    /// controller is a main-thread object.
    @MainActor
    static func sampleAppleMusic() -> AppleMusicSample {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return .unavailable }
        let player = MPMusicPlayerController.systemMusicPlayer
        let state = player.playbackState
        // Interrupted (a call, Siri) reads as paused: the item is still the one queued.
        guard state == .playing || state == .paused || state == .interrupted,
              let item = player.nowPlayingItem,
              let title = item.title, !title.isEmpty else { return .silent }
        let storeID = item.playbackStoreID
        return .track(NowPlayingTrack(
            title: title,
            artist: item.artist ?? item.albumArtist ?? "",
            album: item.albumTitle,
            durationMs: item.playbackDuration > 0 ? Int(item.playbackDuration * 1000) : nil,
            appleMusicId: storeID.isEmpty || storeID == "0" ? nil : storeID,
            source: .appleMusic,
            isPlaying: state == .playing
        ))
    }

    // MARK: Time budget

    /// Runs `operation` until `deadline`; nil when it fails or runs out of time.
    private static func within<T: Sendable>(_ deadline: ContinuousClock.Instant, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
        guard ContinuousClock.now < deadline else { return nil }
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await operation() }
            group.addTask {
                try? await Task.sleep(until: deadline, clock: .continuous)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
