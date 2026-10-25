import ResonoteKit
import SwiftUI

@main
struct ResonoteApp: App {
    @State private var model: AppModel
    @State private var router = Router()
    @State private var nowPlaying: NowPlayingService
    @State private var wasInBackground = true
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _nowPlaying = State(initialValue: NowPlayingService(model: model))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .environment(nowPlaying)
                .preferredColorScheme(.dark)
                .tint(RN.Palette.rustText)
        }
        // Also runs at launch, so the session and now playing refresh once on the way in.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                // Control Center, Notification Center, and system alerts only make the app
                // inactive for a moment: the service samples again only if its last sample
                // is old, and the session is read again only after a real absence.
                nowPlaying.activate()
                guard wasInBackground else { return }
                wasInBackground = false
                // Writes waiting out a backoff go now; the session read (sooner when the
                // share sheet saved something meanwhile) sends them again once it answers.
                model.didReturnToForeground()
                Task { await model.refreshSession(force: false) }
            case .background:
                wasInBackground = true
                nowPlaying.deactivate()
                model.syncBeforeSuspending()
            default:
                break
            }
        }
    }
}
