import AVFAudio
import ResonoteKit
import ShazamKit

/// Identifies music with ShazamKit's managed session. It handles recording itself
/// and, per WWDC23, can also match what the iPhone is playing to AirPods, which
/// makes it a way to catch Spotify or YouTube Music when no API can.
final class SongRecognizer {
    enum Failure: Error, Equatable {
        case microphoneDenied
        case noMatch
        case unavailable(String)

        var message: String {
            switch self {
            case .microphoneDenied: "Resonote needs the microphone to listen. You can allow it in Settings."
            case .noMatch: "Couldn't place that one. Try again in a moment."
            case .unavailable(let detail): "Listening isn't available right now. \(detail)"
            }
        }
    }

    /// Whether the person has turned the microphone off for Resonote.
    static var microphoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    /// Listens for up to `timeout`. Cancelling the calling task, or the timeout, stops
    /// the session (and the microphone) at once rather than when ShazamKit gives up.
    func recognize(timeout: Duration = .seconds(15)) async -> Result<NowPlayingTrack, Failure> {
        guard await AVAudioApplication.requestRecordPermission() else { return .failure(.microphoneDenied) }
        let session = SHManagedSession()
        let outcome = await withTaskGroup(of: SHSession.Result?.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await session.result()
                } onCancel: {
                    session.cancel()
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                session.cancel()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        session.cancel()
        switch outcome {
        case .match(let match)?:
            guard let item = match.mediaItems.first, let title = item.title else { return .failure(.noMatch) }
            // A match vouches that the song was playing just now; the shared playback rule
            // lets that claim lapse after about one song.
            return .success(NowPlayingTrack(
                title: title,
                artist: item.artist ?? "",
                artworkURL: item.artworkURL?.absoluteString,
                isrc: item.isrc,
                appleMusicId: item.appleMusicID,
                url: item.appleMusicURL?.absoluteString ?? item.webURL?.absoluteString,
                source: .shazam,
                isPlaying: true
            ))
        case .error(let error, _)?:
            return .failure(.unavailable(error.localizedDescription))
        case .noMatch?, nil:
            return .failure(.noMatch)
        }
    }
}
