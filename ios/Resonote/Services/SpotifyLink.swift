import Foundation
import ResonoteKit

/// The person's Spotify sign-in (docs/IOS_API.md → Linked accounts): whether this server
/// can do it, the linked account, and linking and unlinking. Authorization Code with PKCE:
/// this makes the verifier and state, the Settings view runs the web sign-in
/// (`ASWebAuthenticationSession` needs a window), and the server exchanges the code with
/// its client secret and keeps the tokens. Keeps `LinkedSources.spotifyLinked` in step so
/// the app and the widget ask `GET /api/now-playing` for Spotify history.
///
/// Spotify's app is in Development Mode: only accounts on its allowlist can sign in, and
/// the server answers 403 for anyone else.
@Observable
final class SpotifyLink {
    enum State: Equatable {
        /// Not asked yet this launch.
        case unknown
        /// The server has no Spotify client id and secret.
        case notConfigured
        case unlinked
        case linked(SpotifyAccount)
    }

    /// One sign-in in progress: the PKCE verifier and the state the callback must carry.
    struct Attempt {
        let url: URL
        let callbackScheme: String
        let verifier: String
        let state: String
    }

    private(set) var state: State = .unknown
    private(set) var isWorking = false
    /// One quiet line under the section after something went wrong.
    private(set) var failure: String?

    @ObservationIgnored private let model: AppModel
    /// Applies a change to the shared `LinkedSources` (owned by `NowPlayingService`).
    @ObservationIgnored var onChange: ((_ linked: Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    var account: SpotifyAccount? {
        if case .linked(let account) = state { return account }
        return nil
    }

    /// Reads the link from the server. Without a live session it forgets what it knew,
    /// so a signed-out phone never shows the last person's account.
    func load() async {
        await model.waitUntilRestored()
        guard model.hasLiveSession else { return reset() }
        do {
            let response = try await model.api.spotifyAccount()
            if let account = response.account {
                state = .linked(account)
                onChange?(true)
            } else {
                state = response.configured ? .unlinked : .notConfigured
                onChange?(false)
            }
        } catch APIError.server(let status, _) where status == 501 {
            state = .notConfigured
            onChange?(false)
        } catch {
            // Offline or a server hiccup: keep what was known.
        }
    }

    /// A fresh verifier and state, and Spotify's authorize page for them; nil (with
    /// `failure` set) when sign-in can't start.
    func begin() async -> Attempt? {
        failure = nil
        let verifier = SpotifyAuth.makeVerifier()
        let state = SpotifyAuth.makeState()
        do {
            let response = try await model.api.spotifyAuthURL(codeChallenge: SpotifyAuth.challenge(for: verifier), state: state)
            return Attempt(url: response.url, callbackScheme: response.callbackScheme, verifier: verifier, state: state)
        } catch APIError.unauthorized {
            failure = "Sign in to Resonote first."
        } catch APIError.server(let status, _) where status == 501 {
            self.state = .notConfigured
            failure = "Spotify sign-in isn't set up on this server."
        } catch {
            failure = "Spotify sign-in isn't available right now."
        }
        return nil
    }

    /// Finishes sign-in with the callback Spotify redirected to. The state must be the
    /// one this attempt sent; a declined sign-in is the person's choice, not an error.
    func finish(callback: URL, attempt: Attempt) async {
        guard let code = SpotifyAuth.code(fromCallback: callback, expectedState: attempt.state) else {
            if SpotifyAuth.error(fromCallback: callback) != "access_denied" {
                failure = "Spotify didn't finish signing in. Try again."
            }
            return
        }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let account = try await model.api.linkSpotify(code: code, codeVerifier: attempt.verifier)
            state = .linked(account)
            onChange?(true)
        } catch APIError.server(let status, _) where status == 403 {
            failure = "This Spotify account isn't on Resonote's allowlist yet."
        } catch APIError.server(let status, _) where status == 400 {
            failure = "Spotify did not accept that sign-in. Try again."
        } catch {
            failure = "Spotify sign-in didn't finish. Check your connection and try again."
        }
    }

    func unlink() async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await model.api.unlinkSpotify()
            state = .unlinked
            onChange?(false)
        } catch {
            failure = "Spotify wasn't unlinked. Check your connection and try again."
        }
    }

    /// The server says the link is gone (revoked, or unlinked on another phone).
    func forget() {
        guard account != nil else { return }
        state = .unlinked
        onChange?(false)
    }

    /// Signing out (or someone else signing in) forgets what this phone knew about the link.
    func reset() {
        state = .unknown
        failure = nil
    }
}
