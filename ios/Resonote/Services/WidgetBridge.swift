import Foundation
import ResonoteKit
import WidgetKit

/// Keeps the shared snapshot that widgets and controls read in step with the app,
/// and asks WidgetKit to reload only when something they show actually changed.
/// Reloads requested while the app is in the foreground don't count against the
/// widget's daily budget. The snapshot is small by design, so reading it here is cheap;
/// callers only call when a field the widget shows changed.
enum WidgetBridge {
    static func personDidChange(signedIn: Bool, handle: String?, habits: TagSuggestions?, recentlyNotedSongIds: [String]) {
        var snapshot = NowPlayingSnapshot.load()
        let before = snapshot
        snapshot.signedIn = signedIn
        snapshot.handle = handle
        snapshot.habits = habits
        snapshot.recentlyNotedSongIds = recentlyNotedSongIds
        save(snapshot, comparedTo: before)
    }

    /// Linked sources changed: the widget samples them itself, so let it start over.
    static func sourcesDidChange() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func nowPlayingDidChange(track: NowPlayingTrack?, resolution: ResolveResponse?) {
        var snapshot = NowPlayingSnapshot.load()
        let before = snapshot
        snapshot.track = track
        if let resolution { snapshot.resolution = resolution }
        save(snapshot, comparedTo: before)
    }

    private static func save(_ snapshot: NowPlayingSnapshot, comparedTo before: NowPlayingSnapshot) {
        var snapshot = snapshot
        var comparable = before
        comparable.updatedAt = snapshot.updatedAt
        guard comparable != snapshot else { return }
        snapshot.updatedAt = ResonoteDate.now()
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
