import ResonoteKit
import SwiftUI

/// A screen pushed onto a tab's navigation stack.
enum Route: Hashable {
    case entity(kind: EntityKind, id: String)
    case profile(handle: String)
    case collection(handle: String, id: String)
    case entry(id: String)
    /// Writing others have published, newest first. A place the person goes to read,
    /// not the home screen: the Now tab opens on their own listening and notes.
    case feed
    case settings
}

/// What the composer is writing about, and whether it edits an existing entry.
struct ComposerContext: Hashable, Identifiable {
    var entityKind: EntityKind
    var entityId: String
    /// Set when editing a published entry.
    var entryId: String?
    /// Seeds a new draft, e.g. the text and tags carried over from the capture sheet.
    var seed: CaptureSeed?

    var id: String { Draft.key(kind: entityKind, entityId: entityId, entryId: entryId) }
}

/// What the quick capture sheet hands to the full composer.
struct CaptureSeed: Hashable {
    var text: String
    var lenses: [MusicLens]
    /// The visibility chosen in capture. A seed never widens it: private stays private.
    var isPublic: Bool
}

/// A modal surface. Only one is presented at a time.
enum Sheet: Identifiable, Hashable {
    case capture(CapturePreset)
    case identify
    case compose(ComposerContext)
    case signIn
    case logListen(songId: String)
    case collect(kind: EntityKind, id: String)
    case tagGenre(kind: EntityKind, id: String)
    case resolveLink(String)
    case editProfile
    case newCollection
    case editCollection(id: String)
    case songCredits(songId: String, songName: String, credits: [SongCredit])
    case songFacts(songId: String, songName: String, facts: [SongFact])

    /// Capture, identify, and shared links are one sheet: a new request while it is up
    /// (the Action button, a widget tag) updates it in place, so words being written
    /// are never thrown away by a replacement sheet.
    var id: String {
        switch self {
        case .capture, .identify, .resolveLink: "capture"
        case .compose(let context): "compose-\(context.id)"
        case .signIn: "sign-in"
        case .logListen(let songId): "listen-\(songId)"
        case .collect(let kind, let id): "collect-\(kind.rawValue)-\(id)"
        case .tagGenre(let kind, let id): "genre-\(kind.rawValue)-\(id)"
        case .editProfile: "edit-profile"
        case .newCollection: "new-collection"
        case .editCollection(let id): "edit-collection-\(id)"
        case .songCredits(let songId, _, _): "credits-\(songId)"
        case .songFacts(let songId, _, _): "facts-\(songId)"
        }
    }

    /// The capture sheet's starting tag, when this is a capture-family sheet.
    var capturePreset: CapturePreset? {
        switch self {
        case .capture(let preset): preset
        case .identify: CapturePreset(origin: "identify")
        case .resolveLink: CapturePreset(origin: "link")
        default: nil
        }
    }
}

/// Navigation state for the whole app. Deep links from widgets, controls, the
/// Action button, and the share extension all arrive through `open(_:trusted:)`.
@Observable
final class Router {
    enum Tab: Hashable { case now, journal, search }

    var tab: Tab = .now
    var nowPath: [Route] = []
    var journalPath: [Route] = []
    var searchPath: [Route] = []
    var sheet: Sheet?
    /// Bumped by every capture, identify, or shared-link request from outside the app.
    /// The capture sheet acts on each one, even when the same request arrives twice.
    private(set) var captureRequest = 0
    /// Set by the presented sheet while it holds input that replacing it would lose.
    var sheetHasUnsavedInput = false

    /// The newest capture request came from outside the app (the Action button, a
    /// control, a widget), where the song on screen may be minutes old.
    @ObservationIgnored private var externalCapturePending = false
    /// A request that arrived while a sheet held unsaved input; it runs once that sheet closes.
    @ObservationIgnored private var deferred: (link: DeepLink, trusted: Bool)?

    /// Pushes onto the visible tab's stack.
    func push(_ route: Route) {
        switch tab {
        case .now: nowPath.append(route)
        case .journal: journalPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    func present(_ sheet: Sheet) {
        self.sheet = sheet
    }

    /// - Parameter trusted: the request came from Resonote itself (an App Intent the
    ///   person ran), so Identify may start listening at once.
    func open(_ link: DeepLink, trusted: Bool = false) {
        if wouldDiscardInput(for: link) {
            deferred = (link, trusted)
            return
        }
        switch link {
        case .capture(let preset):
            tab = .now
            requestCapture(.capture(preset))
        case .identify(let key):
            tab = .now
            // Another app can open resonote://identify; only Resonote's own requests start the microphone.
            let listens = trusted || IdentifyKey.matches(key)
            requestCapture(listens ? .identify : .capture(CapturePreset(origin: "identify-link")))
        case .write(let kind, let id):
            sheet = .compose(ComposerContext(entityKind: kind, entityId: id))
        case .entity(let kind, let id):
            sheet = nil
            push(.entity(kind: kind, id: id))
        case .profile(let handle):
            sheet = nil
            push(.profile(handle: handle))
        case .sharedLink(let url):
            tab = .now
            requestCapture(.resolveLink(url))
        }
    }

    /// Handles `resonote://` URLs, including links tapped inside journal prose.
    func open(url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        open(link)
        return true
    }

    /// Whether the capture sheet now opening (or updating) was asked for from outside
    /// the app. Reading it answers once.
    func consumeExternalCapture() -> Bool {
        defer { externalCapturePending = false }
        return externalCapturePending
    }

    /// Called when a sheet has finished closing: runs a request that waited for it.
    func sheetDidClose() {
        sheetHasUnsavedInput = false
        guard let waiting = deferred else { return }
        deferred = nil
        open(waiting.link, trusted: waiting.trusted)
    }

    private func requestCapture(_ next: Sheet) {
        externalCapturePending = true
        captureRequest += 1
        // Capture, identify, and links share one sheet id, so an open capture sheet updates in place.
        sheet = next
    }

    /// A sheet with typed input is never replaced or closed by a request from outside;
    /// the capture sheet takes capture requests in place, keeping its words.
    private func wouldDiscardInput(for link: DeepLink) -> Bool {
        guard let sheet, sheetHasUnsavedInput else { return false }
        switch link {
        case .capture, .identify, .sharedLink:
            return sheet.capturePreset == nil
        case .write(let kind, let id):
            return sheet.id != Sheet.compose(ComposerContext(entityKind: kind, entityId: id)).id
        case .entity, .profile:
            return true
        }
    }
}

extension View {
    /// Tells the router this sheet holds input a programmatic replacement would lose,
    /// so a widget or the Action button waits for it to close instead.
    func holdsUnsavedInput(_ unsaved: Bool) -> some View {
        modifier(UnsavedInputReporter(unsaved: unsaved))
    }
}

private struct UnsavedInputReporter: ViewModifier {
    @Environment(Router.self) private var router
    let unsaved: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: unsaved, initial: true) { _, value in
                if router.sheetHasUnsavedInput != value { router.sheetHasUnsavedInput = value }
            }
            .onDisappear {
                if router.sheetHasUnsavedInput { router.sheetHasUnsavedInput = false }
            }
    }
}
