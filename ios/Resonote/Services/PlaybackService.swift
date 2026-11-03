import Foundation
import MusicKit
import ResonoteKit
import UIKit

/// A song someone can tap Play on: the catalog song on its page, the capture sheet's
/// song, or the now-playing card's.
struct PlaybackTarget: Hashable, Identifiable {
    var title: String
    var artist: String
    var spotifyId: String?
    var isrc: String?
    var appleMusicId: String?
    var youtubeId: String?
    /// A provider link the source gave (Spotify, Apple Music, or YouTube Music).
    var url: String?

    var id: String { TrackText.matchKey(artist: artist, title: title) }

    init(title: String, artist: String, spotifyId: String? = nil, isrc: String? = nil, appleMusicId: String? = nil, youtubeId: String? = nil, url: String? = nil) {
        self.title = title
        self.artist = artist
        self.spotifyId = spotifyId.flatMap { SpotifyAuth.isTrackId($0) ? $0 : nil }
        self.isrc = isrc.flatMap { $0.isEmpty ? nil : $0 }
        self.appleMusicId = appleMusicId.flatMap { $0.isEmpty ? nil : $0 }
        self.youtubeId = youtubeId.flatMap { $0.isEmpty ? nil : $0 }
        self.url = url.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A catalog song, with its matched track's identifiers when there is one.
    init(song: ResonoteKit.Song, artistName: String?, track: NowPlayingTrack? = nil) {
        self.init(
            title: song.name,
            artist: artistName ?? track?.artist ?? "",
            spotifyId: song.spotifyId ?? track?.spotifyId,
            isrc: track?.isrc,
            appleMusicId: track?.appleMusicId,
            youtubeId: song.youtubeId ?? track?.youtubeId,
            url: track?.url
        )
    }

    init(track: NowPlayingTrack) {
        self.init(title: track.title, artist: track.artist, spotifyId: track.spotifyId, isrc: track.isrc, appleMusicId: track.appleMusicId, youtubeId: track.youtubeId, url: track.url)
    }

    /// The best link to hand to another app: Spotify, then Apple Music, then YouTube
    /// Music, then a link the source gave, then an Apple Music search.
    var bestLink: URL? {
        if let spotifyId, let url = SpotifyAuth.webURL(trackId: spotifyId) { return url }
        if let link = url.flatMap(URL.init(string:)), Self.host(of: link, is: "open.spotify.com") { return link }
        if let appleMusicId, let url = URL(string: "https://music.apple.com/song/\(appleMusicId)") { return url }
        if let link = url.flatMap(URL.init(string:)), Self.host(of: link, is: "music.apple.com") { return link }
        if let youtubeId {
            var components = URLComponents(string: "https://music.youtube.com/watch")
            components?.queryItems = [URLQueryItem(name: "v", value: youtubeId)]
            if let url = components?.url { return url }
        }
        if let link = url.flatMap(URL.init(string:)), let scheme = link.scheme?.lowercased(), scheme == "https" { return link }
        let term = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return nil }
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: term)]
        return components?.url
    }

    private static func host(of url: URL, is host: String) -> Bool {
        url.host()?.lowercased() == host
    }
}

/// Plays a song when the person taps Play, never otherwise. In order:
/// 1. Spotify linked with Premium and a Spotify id → Spotify Connect through the server.
///    With no device open, wakes the Spotify app on the song (`spotify:track:<id>`) and,
///    inside a background task, tries once more after about two seconds on the active
///    smartphone (or the only one, or the active device), never later than 10 s after
///    the tap. Without the app, the web player opens and there is no retry.
/// 2. Apple Music allowed → MusicKit finds the catalog song (by ISRC, then Apple Music
///    id, then title and artist) and the Music app plays it.
/// 3. Otherwise opens the best link.
/// Anything that goes wrong becomes one short message for that song.
///
/// No Spotify iOS SDK: it is a binary framework this project can't build or verify
/// without Xcode, and the deep link plus Connect already wakes the Spotify app.
@Observable
final class PlaybackService {
    /// The song a Play tap is working on.
    private(set) var working: PlaybackTarget.ID?
    /// The last short message, and the song it belongs to.
    private(set) var message: (target: PlaybackTarget.ID, text: String)?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let spotify: SpotifyLink
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var retryBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// How long a message stays before the row goes quiet again.
    private static let messageLifetime: Duration = .seconds(6)
    /// How long the Spotify app gets to register as a Connect device before the retry.
    private static let wakeDelay: Duration = .seconds(2)
    /// A retry later than this after the tap is dropped: the person has moved on.
    private static let retryWindow: TimeInterval = 10
    private static let tapPlayThere = "Spotify is open. Tap play there."

    init(model: AppModel, spotify: SpotifyLink) {
        self.model = model
        self.spotify = spotify
    }

    func message(for target: PlaybackTarget?) -> String? {
        guard let target, let message, message.target == target.id else { return nil }
        return message.text
    }

    func isWorking(on target: PlaybackTarget?) -> Bool {
        guard let target else { return false }
        return working == target.id
    }

    /// Call only from the person's tap.
    func play(_ target: PlaybackTarget) {
        guard working == nil else { return }
        working = target.id
        clearMessage()
        let tappedAt = Date()
        Task {
            // Every path, a cancelled retry included, frees the Play buttons.
            defer { working = nil }
            if let text = await start(target, tappedAt: tappedAt) { show(text, for: target) }
        }
    }

    // MARK: Order

    /// Plays `target` the best way available; returns a message when nothing worked.
    private func start(_ target: PlaybackTarget, tappedAt: Date) async -> String? {
        if spotify.state == .unknown, target.spotifyId != nil { await spotify.load() }
        if let account = spotify.account, account.canPlay, let spotifyId = target.spotifyId, model.hasLiveSession {
            switch await playOnSpotify(spotifyId, tappedAt: tappedAt) {
            case .played: return nil
            case .failed(let text): return text
            case .unavailable: break
            }
        }
        if MusicAuthorization.currentStatus == .authorized, await playInAppleMusic(target) {
            return nil
        }
        guard let link = target.bestLink else { return "Resonote has no link for this song yet." }
        return await UIApplication.shared.open(link) ? nil : "That song couldn't be opened."
    }

    private enum SpotifyOutcome {
        case played
        /// Spotify can't play here; try the next way.
        case unavailable
        case failed(String)
    }

    private func playOnSpotify(_ spotifyId: String, tappedAt: Date) async -> SpotifyOutcome {
        do {
            try await model.api.spotifyPlayback(.play, spotifyId: spotifyId)
            return .played
        } catch SpotifyPlaybackError.noDevice {
            return await wakeSpotifyAndRetry(spotifyId, tappedAt: tappedAt)
        } catch SpotifyPlaybackError.notLinked {
            spotify.forget()
            return .unavailable
        } catch SpotifyPlaybackError.premiumRequired {
            return .unavailable
        } catch {
            return .failed("Spotify didn't start playing. Try again.")
        }
    }

    /// No device has Spotify open: open the Spotify app on the song, then ask Connect once
    /// more. Only the app counts: when it isn't installed and the web player opens instead,
    /// there is no device to retry on.
    private func wakeSpotifyAndRetry(_ spotifyId: String, tappedAt: Date) async -> SpotifyOutcome {
        if let app = SpotifyAuth.appURL(trackId: spotifyId), await UIApplication.shared.open(app) {
            return await retryAfterWake(spotifyId, tappedAt: tappedAt)
        }
        if let web = SpotifyAuth.webURL(trackId: spotifyId), await UIApplication.shared.open(web) {
            return .failed(Self.tapPlayThere)
        }
        return .failed(SpotifyPlaybackError.noDevice.errorDescription ?? "Open Spotify on a device first.")
    }

    /// Resonote is in the background once Spotify opens, so the retry runs inside a
    /// background task; if iOS ends that task, the retry is cancelled. A retry that would
    /// fire more than `retryWindow` after the tap is dropped, so a late resume never
    /// replaces what the person is playing by then.
    private func retryAfterWake(_ spotifyId: String, tappedAt: Date) async -> SpotifyOutcome {
        let api = model.api
        let delay = Self.wakeDelay
        let window = Self.retryWindow
        let retry = Task { () -> Bool in
            func inTime() -> Bool { !Task.isCancelled && Date().timeIntervalSince(tappedAt) <= window }
            do {
                try await Task.sleep(for: delay)
                guard inTime() else { return false }
                let devices = try await api.spotifyDevices()
                guard let device = SpotifyDevice.target(in: devices), inTime() else { return false }
                try await api.spotifyPlayback(.play, spotifyId: spotifyId, deviceId: device.id)
                return true
            } catch {
                return false
            }
        }
        endRetryBackgroundTask()
        retryBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Spotify play retry") { [weak self] in
            retry.cancel()
            self?.endRetryBackgroundTask()
        }
        let played = await retry.value
        endRetryBackgroundTask()
        // The Spotify app is open on the song already; it only didn't start on its own.
        return played ? .played : .failed(Self.tapPlayThere)
    }

    private func endRetryBackgroundTask() {
        guard retryBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(retryBackgroundTask)
        retryBackgroundTask = .invalid
    }

    /// The catalog song through MusicKit, played by the Music app. False when it can't be
    /// found or played, so the link still opens.
    private func playInAppleMusic(_ target: PlaybackTarget) async -> Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        guard let song = await catalogSong(for: target) else { return false }
        let player = SystemMusicPlayer.shared
        player.queue = [song]
        do {
            try await player.play()
            return true
        } catch {
            return false
        }
        #endif
    }

    private func catalogSong(for target: PlaybackTarget) async -> MusicKit.Song? {
        if let isrc = target.isrc {
            let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.isrc, equalTo: isrc)
            if let song = try? await request.response().items.first { return song }
        }
        if let appleMusicId = target.appleMusicId {
            let request = MusicCatalogResourceRequest<MusicKit.Song>(matching: \.id, equalTo: MusicItemID(appleMusicId))
            if let song = try? await request.response().items.first { return song }
        }
        let term = [target.title, target.artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return nil }
        var request = MusicCatalogSearchRequest(term: term, types: [MusicKit.Song.self])
        request.limit = 1
        return try? await request.response().songs.first
    }

    // MARK: Messages

    private func show(_ text: String, for target: PlaybackTarget) {
        message = (target.id, text)
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: Self.messageLifetime)
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    private func clearMessage() {
        clearTask?.cancel()
        message = nil
    }
}
