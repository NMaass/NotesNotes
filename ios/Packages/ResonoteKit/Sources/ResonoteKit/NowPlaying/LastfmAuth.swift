import Foundation

/// Last.fm web auth (docs/IOS_API.md → Linked accounts). The app opens the URL from
/// `APIClient.lastfmAuthURL()` in `ASWebAuthenticationSession`; Last.fm redirects to
/// `resonote://lastfm-auth?token=…`, and the token goes to `APIClient.linkLastfm(token:)`.
/// The server signs `auth.getSession` and keeps the session key.
public enum LastfmAuth {
    public static let callbackScheme = "resonote"
    public static let callbackHost = "lastfm-auth"
    public static let callbackURL = URL(string: "\(callbackScheme)://\(callbackHost)")!

    /// The token in a web-auth callback, or nil for any other URL.
    public static func token(fromCallback url: URL) -> String? {
        guard url.scheme?.lowercased() == callbackScheme, url.host()?.lowercased() == callbackHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value?.trimmingCharacters(in: .whitespaces),
              isValidToken(token) else { return nil }
        return token
    }

    /// Last.fm tokens are 32 alphanumerics; the server accepts the same shape.
    public static func isValidToken(_ token: String) -> Bool {
        token.count == 32 && token.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
}
