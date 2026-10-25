import MediaPlayer
import ResonoteKit

/// Access to the Music app, the only on-device, real-time source iOS offers third
/// parties (it never sees Spotify or YouTube Music), and its change notifications.
/// The sample itself is `NowPlayingRefresher.sampleAppleMusic()`, shared with the
/// widget. Never kept alive in the background.
final class AppleMusicSource {
    enum Access: Equatable {
        case notDetermined, denied, granted
    }

    private var observers: [Task<Void, Never>] = []

    var access: Access {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Asks for Media & Apple Music access. Call only when the person turns the source on.
    func requestAccess() async -> Access {
        _ = await MPMediaLibrary.requestAuthorization()
        return access
    }

    /// Calls `onChange` when the Music app changes track or play state, while the app is active.
    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        guard access == .granted, observers.isEmpty else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        player.beginGeneratingPlaybackNotifications()
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    onChange()
                }
            })
        }
    }

    func stopObserving() {
        guard !observers.isEmpty else { return }
        observers.forEach { $0.cancel() }
        observers.removeAll()
        MPMusicPlayerController.systemMusicPlayer.endGeneratingPlaybackNotifications()
    }
}
