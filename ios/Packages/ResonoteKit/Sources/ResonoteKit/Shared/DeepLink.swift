import Foundation

/// Every way into the app from outside it: widgets, controls, the Action button,
/// App Shortcuts, the share extension, and links. URL form: `resonote://<host>/...`.
public enum DeepLink: Hashable, Sendable {
    /// Open the capture sheet for whatever is playing, optionally with a tag preselected.
    case capture(CapturePreset)
    /// Listen with Shazam, then open capture with the match. Listening starts on its own
    /// only when `key` is this install's `IdentifyKey` (Resonote's own widget); any other
    /// app opening the link gets the capture sheet and a Listen button instead.
    case identify(key: String?)
    /// Open the composer about a specific entity.
    case write(kind: EntityKind, id: String)
    case entity(kind: EntityKind, id: String)
    case profile(handle: String)
    /// Resolve a shared provider link (Spotify, Apple Music, YouTube Music), then capture.
    case sharedLink(String)

    public static let scheme = "resonote"
    /// Opens the app on capture; used only if a link's parts cannot form a URL.
    private static let fallbackURL = URL(string: "resonote://capture")!

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .capture(let preset):
            components.host = "capture"
            components.queryItems = preset.queryItems.isEmpty ? nil : preset.queryItems
        case .identify(let key):
            components.host = "identify"
            if let key { components.queryItems = [URLQueryItem(name: "k", value: key)] }
        case .write(let kind, let id):
            components.host = "write"
            components.path = "/\(kind.rawValue)/\(id)"
        case .entity(let kind, let id):
            components.host = "entity"
            components.path = "/\(kind.rawValue)/\(id)"
        case .profile(let handle):
            components.host = "profile"
            components.path = "/\(handle)"
        case .sharedLink(let link):
            components.host = "link"
            components.queryItems = [URLQueryItem(name: "url", value: link)]
        }
        return components.url ?? Self.fallbackURL
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, last in last })
        switch components.host {
        case "capture":
            self = .capture(CapturePreset(query: query))
        case "identify":
            self = .identify(key: query["k"])
        case "write":
            guard parts.count == 2, let kind = EntityKind(rawValue: parts[0]) else { return nil }
            self = .write(kind: kind, id: parts[1])
        case "entity":
            guard parts.count == 2, let kind = EntityKind(rawValue: parts[0]) else { return nil }
            self = .entity(kind: kind, id: parts[1])
        case "profile":
            guard let handle = parts.first else { return nil }
            self = .profile(handle: handle)
        case "link":
            guard let link = query["url"] else { return nil }
            self = .sharedLink(link)
        default:
            return nil
        }
    }
}

/// A tag tapped on a widget before the app opened; capture starts with it selected.
public struct CapturePreset: Hashable, Sendable, Codable {
    public var lens: MusicLens?
    public var mood: String?
    public var genreId: String?
    /// Where the capture began, for copy like "From your widget" and analytics-free debugging.
    public var origin: String?

    public init(lens: MusicLens? = nil, mood: String? = nil, genreId: String? = nil, origin: String? = nil) {
        self.lens = lens
        self.mood = mood
        self.genreId = genreId
        self.origin = origin
    }

    init(query: [String: String]) {
        lens = query["lens"].flatMap(MusicLens.init(rawValue:))
        mood = query["mood"]
        genreId = query["genre"]
        origin = query["from"]
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let lens { items.append(URLQueryItem(name: "lens", value: lens.rawValue)) }
        if let mood { items.append(URLQueryItem(name: "mood", value: mood)) }
        if let genreId { items.append(URLQueryItem(name: "genre", value: genreId)) }
        if let origin { items.append(URLQueryItem(name: "from", value: origin)) }
        return items
    }
}

/// A per-install secret kept in the App Group, which only Resonote's own targets can
/// read. The widget puts it in its Identify link, so the app can tell its own widget's
/// request (start listening) from another app opening `resonote://identify` (don't).
public enum IdentifyKey {
    private static let defaultsKey = "identify-key"

    /// This install's key, created on first use.
    public static var current: String {
        let defaults = AppGroup.defaults
        if let key = defaults.string(forKey: defaultsKey), !key.isEmpty { return key }
        let key = Identifiers.make()
        defaults.set(key, forKey: defaultsKey)
        return key
    }

    /// Whether `key` came from one of Resonote's own targets.
    public static func matches(_ key: String?) -> Bool {
        guard let key, !key.isEmpty, let stored = AppGroup.defaults.string(forKey: defaultsKey) else { return false }
        return key == stored
    }
}
