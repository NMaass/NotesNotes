import Foundation
import MusicKit
import ResonoteKit

/// Apple Music through MusicKit: listening history for the capture sheet's recent
/// plays, and the Music app's current item as a catalog song with an ISRC. Uses the
/// same Media & Apple Music permission as `AppleMusicSource`; never asks for it.
///
/// `MusicKit.Song` is spelled out everywhere: ResonoteKit has a `Song` too.
enum AppleMusicHistory {
    /// Rows asked of each history source.
    static let limit = 10
    private static let artworkSize = 300

    /// Recently played (in order, undated, from every device on the account) and library
    /// songs by `lastPlayedDate`. Empty without access; a failed request is just empty.
    static func load() async -> [RecentPlay] {
        guard MusicAuthorization.currentStatus == .authorized else { return [] }
        async let recent = recentlyPlayed()
        async let library = libraryLastPlayed()
        return await recent + library
    }

    private static func recentlyPlayed() async -> [RecentPlay] {
        var request = MusicRecentlyPlayedRequest<MusicKit.Song>()
        request.limit = limit
        guard let response = try? await request.response() else { return [] }
        // Apple's list carries no play times; a song's own `lastPlayedDate` sometimes does.
        return response.items.map { play(from: $0, source: .appleMusicRecent, playedAt: $0.lastPlayedDate) }
    }

    private static func libraryLastPlayed() async -> [RecentPlay] {
        var request = MusicLibraryRequest<MusicKit.Song>()
        request.sort(by: \.lastPlayedDate, ascending: false)
        request.limit = limit
        guard let response = try? await request.response() else { return [] }
        return response.items.compactMap { song in
            guard let played = song.lastPlayedDate else { return nil }
            return play(from: song, source: .libraryLastPlayed, playedAt: played)
        }
    }

    private static func play(from song: MusicKit.Song, source: RecentPlay.Source, playedAt: Date?) -> RecentPlay {
        RecentPlay(
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle,
            playedAt: playedAt,
            source: source,
            durationMs: song.duration.map { Int($0 * 1000) },
            isrc: song.isrc,
            appleMusicId: catalogID(song.id),
            url: song.url?.absoluteString,
            artworkURL: webArtwork(song.artwork)
        )
    }

    // MARK: The Music app's current item

    /// The Music app's current item as MusicKit sees it. `SystemMusicPlayer` doesn't exist
    /// on Mac Catalyst (the typecheck target), so there it is always nil.
    static func currentSong() -> MusicKit.Song? {
        #if targetEnvironment(macCatalyst)
        return nil
        #else
        guard MusicAuthorization.currentStatus == .authorized,
              case .song(let song)? = SystemMusicPlayer.shared.queue.currentEntry?.item else { return nil }
        return song
        #endif
    }

    /// `track` (a Music app sample) with what MusicKit knows about the same item: the
    /// ISRC above all, which the resolver treats as an exact match, instead of matching
    /// `MPMediaItem` text. Unchanged when MusicKit has a different song or none.
    static func enriched(_ track: NowPlayingTrack) -> NowPlayingTrack {
        guard let song = currentSong(),
              TrackText.matchKey(artist: song.artistName, title: song.title) == TrackText.matchKey(artist: track.artist, title: track.title) else { return track }
        var track = track
        track.isrc = track.isrc ?? song.isrc
        track.appleMusicId = track.appleMusicId ?? catalogID(song.id)
        track.album = track.album ?? song.albumTitle
        track.durationMs = track.durationMs ?? song.duration.map { Int($0 * 1000) }
        track.artworkURL = track.artworkURL ?? webArtwork(song.artwork)
        track.url = track.url ?? song.url?.absoluteString
        return track
    }

    // MARK: Helpers

    /// Catalog ids are numeric; library ids ("i.…") mean nothing to the backend.
    private static func catalogID(_ id: MusicItemID) -> String? {
        let raw = id.rawValue
        return !raw.isEmpty && raw.allSatisfy(\.isNumber) ? raw : nil
    }

    /// Only web artwork leaves the device: library art can be a local-only URL.
    private static func webArtwork(_ artwork: Artwork?) -> String? {
        guard let url = artwork?.url(width: artworkSize, height: artworkSize),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url.absoluteString
    }
}
