import CryptoKit
import Foundation

/// Spotify sign-in: Authorization Code with PKCE (RFC 7636), the code exchanged on the
/// server with the client secret (docs/IOS_API.md → Linked accounts). The app makes a
/// verifier and a state, asks `APIClient.spotifyAuthURL(codeChallenge:state:)` for the
/// authorize page, opens it in `ASWebAuthenticationSession`, and Spotify redirects to
/// `resonote://spotify-auth?code=…&state=…`. The code and the verifier go to
/// `APIClient.linkSpotify(code:codeVerifier:)`; tokens never reach the phone.
public enum SpotifyAuth {
    public static let callbackScheme = "resonote"
    public static let callbackHost = "spotify-auth"
    public static let callbackURL = URL(string: "\(callbackScheme)://\(callbackHost)")!

    /// A fresh code verifier: 32 random bytes, base64url, 43 characters (RFC 7636 §4.1).
    public static func makeVerifier() -> String {
        base64URL(randomBytes(32))
    }

    /// The S256 code challenge for `verifier`: base64url(SHA-256(ASCII(verifier))), no padding.
    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A fresh state: 16 random bytes, base64url, 22 characters of `[A-Za-z0-9_-]`.
    public static func makeState() -> String {
        base64URL(randomBytes(16))
    }

    /// The authorization code in a callback, or nil for any other URL, a state that isn't
    /// `expectedState`, an `error=` callback (the person declined, or Spotify refused), or
    /// a missing code.
    public static func code(fromCallback url: URL, expectedState: String) -> String? {
        guard isCallback(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespaces)
        }
        guard value("error") == nil,
              let state = value("state"), !expectedState.isEmpty, state == expectedState,
              let code = value("code"), !code.isEmpty else { return nil }
        return code
    }

    /// The `error` Spotify put in the callback (`access_denied` when the person declined).
    public static func error(fromCallback url: URL) -> String? {
        guard isCallback(url) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "error" })?.value
    }

    public static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme && url.host()?.lowercased() == callbackHost
    }

    /// The `spotify:track:<id>` URI that wakes the Spotify app on that song.
    public static func appURL(trackId: String) -> URL? {
        guard isTrackId(trackId) else { return nil }
        return URL(string: "spotify:track:\(trackId)")
    }

    /// The web player page for a track, for when the Spotify app isn't installed.
    public static func webURL(trackId: String) -> URL? {
        guard isTrackId(trackId) else { return nil }
        return URL(string: "https://open.spotify.com/track/\(trackId)")
    }

    /// Spotify track ids are 22 base-62 characters; the server accepts the same shape.
    public static func isTrackId(_ id: String) -> Bool {
        id.count == 22 && id.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: Helpers

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `SystemRandomNumberGenerator` is a cryptographically secure source on Apple platforms.
    private static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
