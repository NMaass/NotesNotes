import Foundation

public enum APIError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case server(status: Int, message: String)
    case transport(String)
    case decoding(String)
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Sign in to continue."
        case .server(_, let message): message
        case .transport: "Resonote can't be reached right now."
        case .decoding: "Resonote sent something this version can't read."
        case .notConfigured: "Cloud data isn't configured on this server."
        }
    }

    /// Transient failures are worth retrying; everything else needs a person. Only a 4xx
    /// (other than a timeout or throttling) says the request itself will never work.
    public var isTransient: Bool {
        switch self {
        case .transport, .notConfigured, .decoding: true
        case .server(let status, _): !(400..<500).contains(status) || status == 408 || status == 429
        case .unauthorized: false
        }
    }
}

/// Talks to the Resonote backend. Stateless apart from its configuration, so the
/// app, widget extension, and share extension can each make their own.
public struct APIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://resonote.nmaass.dev")!

    public let baseURL: URL
    private let session: URLSession
    private let token: @Sendable () -> String?

    /// - Parameter token: returns the current bearer token, read at request time.
    public init(baseURL: URL = APIClient.defaultBaseURL, session: URLSession = .shared, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.token = token
    }

    // MARK: Auth

    public func requestCode(email: String) async throws -> RequestCodeResponse {
        try await send("POST", "/api/auth/request-code", body: ["email": email])
    }

    public func verify(email: String, code: String) async throws -> VerifyResponse {
        try await send("POST", "/api/auth/verify", body: ["email": email, "code": code, "client": "ios"])
    }

    public func session() async throws -> SessionResponse {
        try await send("GET", "/api/auth/session")
    }

    public func signOut() async throws {
        let _: OKResponse = try await send("POST", "/api/auth/signout", body: [String: String]())
    }

    /// new: deletes the signed-in account and everything it made, and ends every session.
    public func deleteAccount() async throws {
        let _: OKResponse = try await send("DELETE", "/api/account")
    }

    // MARK: Linked accounts

    /// new: whether Last.fm web auth is available here, and the linked account if any.
    public func lastfmAccount() async throws -> LastfmAccountResponse {
        try await send("GET", "/api/account/lastfm")
    }

    /// new: the Last.fm page that asks the person to approve Resonote. It redirects to
    /// `resonote://lastfm-auth?token=…`; pass that token to `linkLastfm(token:)`.
    public func lastfmAuthURL() async throws -> LastfmAuthURLResponse {
        try await send("GET", "/api/account/lastfm/auth-url")
    }

    /// new: exchanges a web-auth token for a Last.fm session the server keeps. A token
    /// works once; a refused one (400) needs a new approval, not a retry.
    public func linkLastfm(token: String) async throws -> LastfmAccount {
        let response: LastfmLinkResponse = try await send("POST", "/api/account/lastfm/session", body: ["token": token])
        return response.account
    }

    /// new: forgets the linked Last.fm account and its session. Idempotent.
    public func unlinkLastfm() async throws {
        let _: OKResponse = try await send("DELETE", "/api/account/lastfm")
    }

    // MARK: Safety

    /// new: tells Resonote that an entry or a profile breaks the rules.
    public func report(_ request: ReportRequest) async throws {
        let _: OKResponse = try await send("POST", "/api/moderation/reports", body: request)
    }

    /// new: the people the signed-in person has blocked.
    public func blockedProfiles() async throws -> [Profile] {
        let response: BlockedProfilesResponse = try await send("GET", "/api/moderation/blocks")
        return response.profiles
    }

    /// new: hides a person's writing from the signed-in person, everywhere. Idempotent.
    public func block(profileId: String) async throws {
        let _: OKResponse = try await send("POST", "/api/moderation/blocks", body: ["profileId": profileId])
    }

    /// new: undoes `block(profileId:)`. Idempotent.
    public func unblock(profileId: String) async throws {
        let _: OKResponse = try await send("DELETE", "/api/moderation/blocks", query: ["profileId": profileId])
    }

    // MARK: Writes

    public func sync(_ operation: SyncOperation) async throws {
        let _: OKResponse = try await send("POST", "/api/sync", body: operation)
    }

    /// Sends an already-encoded `SyncOperation` (used by the durable outbox).
    public func syncRaw(_ body: Data) async throws {
        let _: OKResponse = try await send("POST", "/api/sync", query: [:], bodyData: body)
    }

    // MARK: Reads

    public func profile(handle: String) async throws -> ProfileBundle {
        let handle = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        let response: PublicProfileResponse = try await send("GET", "/api/profiles/\(Self.pathComponent(handle))")
        guard let bundle = response.bundle else { throw APIError.server(status: 404, message: response.error ?? "Profile not found.") }
        return bundle
    }

    /// new: seeded catalog plus everything imported into D1.
    public func searchCatalog(_ query: String, limit: Int = 20) async throws -> [SearchResult] {
        let response: SearchResponse = try await send("GET", "/api/catalog/search", query: ["q": query, "limit": String(limit)])
        return response.results
    }

    /// Wider MusicBrainz discovery. Results are not permanent pages until imported.
    public func searchMusicBrainz(_ query: String, kind: EntityKind = .song) async throws -> [SearchResult] {
        let response: SearchResponse = try await send("GET", "/api/music/search", query: ["q": query, "kind": kind.rawValue])
        return response.results
    }

    /// Resolves a MusicBrainz result into permanent catalog rows (artist, release group, tracks).
    public func importFromMusicBrainz(kind: EntityKind, mbid: String) async throws -> CatalogSlice {
        let response: ImportResponse = try await send("POST", "/api/music/import", body: ["kind": kind.rawValue, "mbid": mbid])
        guard let bundle = response.bundle else { throw APIError.server(status: 502, message: response.error ?? "Import failed.") }
        return bundle
    }

    /// new
    public func entity(kind: EntityKind, id: String) async throws -> EntityDetail {
        try await send("GET", "/api/catalog/entity", query: ["kind": kind.rawValue, "id": id])
    }

    /// new
    public func genres() async throws -> [Genre] {
        let response: GenresResponse = try await send("GET", "/api/catalog/genres")
        return response.genres
    }

    /// new
    public func feed(limit: Int = 30, before: String? = nil) async throws -> FeedResponse {
        var query = ["limit": String(limit)]
        if let before { query["before"] = before }
        return try await send("GET", "/api/feed", query: query)
    }

    /// new: map a now-playing track to a catalog song, importing it when needed.
    public func resolve(_ request: ResolveRequest) async throws -> ResolveResponse {
        try await send("POST", "/api/music/resolve", body: request)
    }

    /// new: the freshest track and the recent plays across linked Last.fm and
    /// ListenBrainz accounts. A Last.fm account linked through web auth is used even
    /// when `lastfm` is nil.
    /// With `before`, `recent` is the history before that moment and `track` is nil.
    public func remoteNowPlaying(lastfm: String?, listenbrainz: String?, resolve: Bool, before: Date? = nil) async throws -> RemoteNowPlayingResponse {
        var query: [String: String] = [:]
        if let lastfm, !lastfm.isEmpty { query["lastfm"] = lastfm }
        if let listenbrainz, !listenbrainz.isEmpty { query["listenbrainz"] = listenbrainz }
        if resolve { query["resolve"] = "1" }
        if let before { query["before"] = ResonoteDate.string(from: before) }
        return try await send("GET", "/api/now-playing", query: query)
    }

    // MARK: Transport

    private struct OKResponse: Decodable, Sendable {
        var ok: Bool?
    }

    private struct ErrorBody: Decodable, Sendable {
        var ok: Bool?
        var error: String?
    }

    /// A 2xx body read in one parse: either `{ ok: false, error }` or the expected value.
    private struct Envelope<Value: Decodable>: Decodable {
        var failure: String?
        var value: Value?

        private enum Keys: String, CodingKey { case ok, error }

        init(from decoder: any Decoder) throws {
            if let c = try? decoder.container(keyedBy: Keys.self),
               (try? c.decodeIfPresent(Bool.self, forKey: .ok)) == false {
                failure = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? "Request failed."
                value = nil
                return
            }
            failure = nil
            value = try Value(from: decoder)
        }
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }

    private func send<Response: Decodable & Sendable>(_ method: String, _ path: String, query: [String: String] = [:]) async throws -> Response {
        try await send(method, path, query: query, bodyData: nil)
    }

    private func send<Response: Decodable & Sendable, Body: Encodable>(_ method: String, _ path: String, query: [String: String] = [:], body: Body) async throws -> Response {
        try await send(method, path, query: query, bodyData: try JSONEncoder().encode(body))
    }

    /// The network round trip and JSON decoding run off the caller's actor, so a large
    /// response never decodes on the main thread.
    @concurrent
    private func send<Response: Decodable & Sendable>(_ method: String, _ path: String, query: [String: String], bodyData: Data?) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw APIError.transport("Bad URL for \(path)") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ResonoteiOS/1", forHTTPHeaderField: "X-Resonote-Client")
        if let token = token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            if status == 401 { throw APIError.unauthorized }
            if status == 503 { throw APIError.notConfigured }
            throw APIError.server(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }

        let envelope: Envelope<Response>
        do {
            envelope = try JSONDecoder().decode(Envelope<Response>.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
        if let failure = envelope.failure {
            throw APIError.server(status: status, message: failure)
        }
        guard let value = envelope.value else { throw APIError.decoding("Empty response for \(path)") }
        return value
    }
}
