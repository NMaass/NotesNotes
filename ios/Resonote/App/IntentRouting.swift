import AppIntents
import ResonoteKit
import SwiftUI

extension View {
    /// Routes App Intents — controls, the Action button, App Shortcuts, and a person's
    /// own Shortcuts — into the Router. The handlers run before the app comes forward,
    /// so the right sheet is already up when it does.
    func appIntentRouting() -> some View {
        modifier(AppIntentRouting())
    }
}

private struct AppIntentRouting: ViewModifier {
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying

    func body(content: Content) -> some View {
        content
            .onAppIntentExecution(OpenResonoteIntent.self) { intent in
                switch intent.target {
                case .capture: router.open(.capture(CapturePreset(origin: "control")))
                case .identify: router.open(.identify(key: nil), trusted: true)
                }
            }
            .onAppIntentExecution(NoteSongIntent.self) { intent in
                // Current before the sheet opens, so capture starts on the named song.
                if let track = intent.track { nowPlaying.present(track) }
                router.open(.capture(CapturePreset(origin: CaptureSheet.shortcutOrigin)))
            }
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}
