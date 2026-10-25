import ResonoteKit
import SwiftUI

/// Three tabs — Now, Journal, Search — with the now-playing bar riding above the tab
/// bar, like the mini player in Music. Every modal goes through `Router.sheet`.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Now", systemImage: "record.circle", value: Router.Tab.now) {
                NavigationStack(path: $router.nowPath) {
                    NowView().withRoutes()
                }
            }
            Tab("Journal", systemImage: "book.closed", value: Router.Tab.journal) {
                NavigationStack(path: $router.journalPath) {
                    JournalView().withRoutes()
                }
            }
            Tab(value: Router.Tab.search, role: .search) {
                NavigationStack(path: $router.searchPath) {
                    SearchView().withRoutes()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            NowPlayingAccessory()
        }
        .sheet(item: $router.sheet, onDismiss: { router.sheetDidClose() }) { sheet in
            SheetHost(sheet: sheet)
                .signInSheet(enabled: true)
        }
        .signInSheet(enabled: router.sheet == nil)
        .environment(\.openURL, OpenURLAction { url in
            router.open(url: url) ? .handled : .systemAction
        })
        .onOpenURL { url in _ = router.open(url: url) }
        .overlay(alignment: .top) {
            VStack(spacing: RN.Space.xs) {
                SessionExpiredBanner()
                SyncNoticeBanner()
            }
        }
        .appIntentRouting()
    }
}

/// Presents whichever modal the router asks for.
struct SheetHost: View {
    let sheet: Sheet

    var body: some View {
        switch sheet {
        case .capture, .identify, .resolveLink:
            // One branch, so a new capture request updates the open sheet instead of replacing it.
            CaptureSheet(preset: sheet.capturePreset ?? CapturePreset(), startsListening: sheet == .identify, link: sharedLink)
        case .compose(let context):
            ComposerView(context: context)
        case .signIn:
            SignInSheet()
        case .logListen(let songId):
            LogListenSheet(songId: songId)
        case .collect(let kind, let id):
            CollectSheet(kind: kind, id: id)
        case .tagGenre(let kind, let id):
            GenreTagSheet(kind: kind, id: id)
        case .editProfile:
            EditProfileHost()
        case .newCollection:
            NewCollectionSheet()
        case .editCollection(let id):
            EditCollectionHost(collectionId: id)
        case .songCredits(_, let songName, let credits):
            EntityCreditsSheet(songName: songName, credits: credits)
        case .songFacts(_, let songName, let facts):
            EntityFactsSheet(songName: songName, facts: facts)
        }
    }

    private var sharedLink: String? {
        if case .resolveLink(let link) = sheet { return link }
        return nil
    }
}

extension View {
    /// Registers every pushable screen on a navigation stack.
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .entity(let kind, let id):
                EntityView(kind: kind, id: id)
            case .profile(let handle):
                ProfileView(handle: handle)
            case .collection(let handle, let id):
                CollectionView(handle: handle, collectionId: id)
            case .entry(let id):
                EntryDetailView(entryId: id)
            case .settings:
                SettingsView()
            }
        }
    }

    /// Presents sign-in from the topmost presenter only (a sheet can't present over another presenter's sheet).
    func signInSheet(enabled: Bool) -> some View {
        modifier(SignInPresenter(enabled: enabled))
    }
}

private struct SignInPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let enabled: Bool

    func body(content: Content) -> some View {
        content.sheet(
            isPresented: Binding(
                get: { enabled && model.isSignInPresented },
                // Only a dismissal the person made cancels; completing sign-in clears the flag first.
                set: { presented in if !presented, model.isSignInPresented { model.cancelSignIn() } }
            ),
            onDismiss: { model.signInSheetDidDismiss() }
        ) {
            SignInSheet()
        }
    }
}

/// One quiet line when a write could not reach the server, or was refused. VoiceOver
/// hears it too, and it stays while VoiceOver is reading.
private struct SyncNoticeBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    var body: some View {
        if let notice = model.syncNotice {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(RN.Palette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 4)
                .onTapGesture { model.syncNotice = nil }
                .task(id: notice) {
                    AccessibilityNotification.Announcement(notice).post()
                    try? await Task.sleep(for: .seconds(voiceOver ? 12 : 5))
                    guard !Task.isCancelled, model.syncNotice == notice else { return }
                    model.syncNotice = nil
                }
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: "Dismiss") { model.syncNotice = nil }
        }
    }
}

/// While the server no longer accepts this device's session: everything is still here,
/// and signing in again sends what's waiting. Stays until the person acts.
private struct SessionExpiredBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sessionExpired {
            HStack(spacing: RN.Space.s) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(2)
                Button("Sign in") { model.renewSession() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.rustText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var message: String {
        let count = model.unsyncedWrites
        guard count > 0 else { return "Your session ended. Sign in to keep syncing." }
        return "Sign in to finish syncing \(JournalCopy.count(count, "change"))."
    }
}
