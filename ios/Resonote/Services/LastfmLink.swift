import Foundation
import ResonoteKit

/// The person's Last.fm link through web auth (docs/IOS_API.md → Linked accounts):
/// whether this server can do it, the linked account, and linking and unlinking. The
/// web sign-in itself runs in the Settings view (`ASWebAuthenticationSession` needs a
/// window); this owns the server side and keeps `LinkedSources` in step, so the
/// widget's refresher reads Last.fm without a typed username.
@Observable
final class LastfmLink {
    enum State: Equatable {
        /// Not asked yet this launch.
        case unknown
        /// The server has no Last.fm API key and shared secret: only a typed username works.
        case notConfigured
        case unlinked
        case linked(LastfmAccount)
    }

    private(set) var state: State = .unknown
    private(set) var isWorking = false
    /// One quiet line under the row after something went wrong.
    private(set) var failure: String?

    @ObservationIgnored private let model: AppModel
    /// Applies a change to the shared `LinkedSources` (owned by `NowPlayingService`).
    @ObservationIgnored var onChange: ((_ linked: Bool, _ username: String?) -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    private func updateSources(_ linked: Bool, _ username: String?) {
        onChange?(linked, username)
    }

    var account: LastfmAccount? {
        if case .linked(let account) = state { return account }
        return nil
    }

    /// Reads the link from the server. Without a live session it forgets what it knew,
    /// so a signed-out phone never shows the last person's account.
    func load() async {
        await model.waitUntilRestored()
        guard model.hasLiveSession else { return reset() }
        guard let response = try? await model.api.lastfmAccount() else { return }
        if let account = response.account {
            state = .linked(account)
            updateSources(true, account.username)
        } else {
            state = response.configured ? .unlinked : .notConfigured
            // Linked on another phone and since unlinked, or never linked: stop relying on it.
            updateSources(false, nil)
        }
    }

    /// The Last.fm approval page, or nil (with `failure` set) when it can't be opened.
    func authURL() async -> LastfmAuthURLResponse? {
        failure = nil
        do {
            return try await model.api.lastfmAuthURL()
        } catch APIError.unauthorized {
            failure = "Sign in to Resonote first."
        } catch {
            failure = "Last.fm sign-in isn't available right now."
        }
        return nil
    }

    /// Finishes web auth with the callback Last.fm redirected to.
    func finish(callback: URL) async {
        guard let token = LastfmAuth.token(fromCallback: callback) else {
            failure = "Last.fm didn't finish signing in. Try again."
            return
        }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let account = try await model.api.linkLastfm(token: token)
            state = .linked(account)
            updateSources(true, account.username)
        } catch {
            failure = "Last.fm didn't accept that sign-in. Try again."
        }
    }

    func unlink() async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await model.api.unlinkLastfm()
            state = .unlinked
            updateSources(false, nil)
        } catch {
            failure = "Last.fm wasn't unlinked. Check your connection and try again."
        }
    }

    /// Signing out (or someone else signing in) forgets what this phone knew about the link.
    func reset() {
        state = .unknown
        failure = nil
    }
}
