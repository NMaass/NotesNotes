import Foundation
import Synchronization
import Testing
@testable import ResonoteKit

/// End-to-end contract checks against a running backend with a local D1 and no mail
/// provider (so sign-in returns a dev code). Skipped unless `RESONOTE_LIVE_BASE_URL`
/// is set, e.g.:
///
///     RESONOTE_LIVE_BASE_URL=http://localhost:3000 ios/scripts/test-kit.sh --filter LiveContract
///
/// Never point this at production: it creates an account and writes data.
@Suite(.serialized, .enabled(if: LiveContract.baseURL != nil))
struct LiveContractTests {
    static let lithium = "40000000-0000-0000-0000-000000000001"

    @Test func fullNativeFlow() async throws {
        let session = try await LiveContract.signedIn()
        let api = session.api

        // Session works with the bearer token alone.
        let me = try await api.session()
        #expect(me.authenticated)
        let profile = try #require(me.bundle?.profile)

        // Catalog reads decode.
        let search = try await api.searchCatalog("Lithium")
        #expect(search.contains { $0.entity.id == Self.lithium })
        let detail = try await api.entity(kind: .song, id: Self.lithium)
        #expect(detail.entity.name == "Lithium")
        #expect(detail.album?.name == "Nevermind")
        let genres = try await api.genres()
        #expect(genres.count >= 7)

        // Writes: entry → visible in feed and on the entity → deleted.
        let entryId = Identifiers.make()
        let now = ResonoteDate.now()
        let document = RichDocument.plain("Contract test: the chorus changes shape.")
        let entry = JournalEntry(id: entryId, profileId: profile.id, entityId: Self.lithium, entityKind: .song, document: document, plainText: document.plainText, lenses: [.composition], isPublic: true, createdAt: now, updatedAt: now)
        try await api.sync(.entry(entry))
        let feed = try await api.feed(limit: 10)
        #expect(feed.entries.contains { $0.id == entryId })
        #expect(feed.profiles.contains { $0.id == profile.id })
        let withEntry = try await api.entity(kind: .song, id: Self.lithium)
        #expect(withEntry.entries.contains { $0.id == entryId })
        try await api.sync(.deleteEntry(id: entryId))
        let afterDelete = try await api.entity(kind: .song, id: Self.lithium)
        #expect(!afterDelete.entries.contains { $0.id == entryId })

        // The rest of the sync surface.
        try await api.sync(.like(id: Identifiers.make(), entityId: Self.lithium, entityKind: .song, clientVersion: 1, liked: true))
        try await api.sync(.pin(targetType: .entity, targetId: Self.lithium, position: 0, pinned: true))
        try await api.sync(.listen(ListenLog(id: Identifiers.make(), profileId: profile.id, songId: Self.lithium, moods: ["warm"], listenedAt: ResonoteDate.now())))
        let firstGenre = try #require(genres.first)
        try await api.sync(.genreAssertion(entityId: Self.lithium, entityKind: .song, genreId: firstGenre.id, asserted: true))
        let collectionId = Identifiers.make()
        let collection = MusicCollection(id: collectionId, profileId: profile.id, name: "Contract", slug: "contract-\(collectionId.prefix(6))", description: "", isPublic: true, items: [CollectionItem(id: Identifiers.make(), entityId: Self.lithium, entityKind: .song, position: 0)], createdAt: now, updatedAt: now)
        try await api.sync(.collection(collection))
        try await api.sync(.profile(displayName: "Contract", bio: "", avatarUrl: nil, profileSongId: Self.lithium, genreIds: [firstGenre.id]))

        let bundle = try #require(try await api.session().bundle)
        #expect(bundle.likes.contains { $0.entityId == Self.lithium })
        #expect(bundle.pins.contains { $0.targetId == Self.lithium })
        #expect(bundle.listens.contains { $0.songId == Self.lithium })
        #expect(bundle.genreAssertions.contains { $0.genreId == firstGenre.id })
        #expect(bundle.collections.contains { $0.id == collectionId })
        #expect(bundle.profile.profileSongId == Self.lithium)

        try await api.sync(.deleteCollection(id: collectionId))
        try await api.sync(.like(id: "", entityId: Self.lithium, entityKind: .song, clientVersion: 2, liked: false))
        try await api.sync(.pin(targetType: .entity, targetId: Self.lithium, position: 0, pinned: false))
        let cleaned = try #require(try await api.session().bundle)
        #expect(!cleaned.collections.contains { $0.id == collectionId })
        #expect(!cleaned.likes.contains { $0.entityId == Self.lithium })

        // Public profile hides listens.
        let publicBundle = try await api.profile(handle: profile.handle)
        #expect(publicBundle.listens.isEmpty)

        // Resolving a seed song by text needs no network beyond the server.
        let resolution = try await api.resolve(ResolveRequest(track: NowPlayingTrack(title: "Lithium", artist: "Nirvana", source: .manual, isPlaying: false)))
        #expect(resolution.song?.id == Self.lithium)
        #expect(!resolution.suggestions.prompt.isEmpty)
        #expect(!resolution.suggestions.lenses.isEmpty)

        // Now-playing decodes even when nothing is playing.
        _ = try await api.remoteNowPlaying(lastfm: nil, listenbrainz: "rob", resolve: false)

        try await api.signOut()
        session.token.withLock { $0 = nil }
        let signedOut = try await api.session()
        #expect(!signedOut.authenticated)
    }

    @Test func signedOutWritesAreRejected() async throws {
        let api = APIClient(baseURL: try #require(LiveContract.baseURL), token: { nil })
        await #expect(throws: APIError.unauthorized) {
            try await api.sync(.listen(ListenLog(id: Identifiers.make(), profileId: "", songId: Self.lithium, moods: [], listenedAt: ResonoteDate.now())))
        }
        await #expect(throws: APIError.unauthorized) {
            _ = try await api.resolve(ResolveRequest(track: NowPlayingTrack(title: "Lithium", artist: "Nirvana", source: .manual, isPlaying: false)))
        }
    }

    /// Report, block, and account deletion — the App Review 1.2 and 5.1.1(v) surfaces.
    @Test func safetyAndAccountDeletion() async throws {
        let writer = try await LiveContract.signedIn()
        let reader = try await LiveContract.signedIn()
        let writerProfile = try #require(try await writer.api.session().bundle?.profile)

        let entryId = Identifiers.make()
        let now = ResonoteDate.now()
        let document = RichDocument.plain("Contract test: written to be reported.")
        try await writer.api.sync(.entry(JournalEntry(id: entryId, profileId: writerProfile.id, entityId: Self.lithium, entityKind: .song, document: document, plainText: document.plainText, isPublic: true, createdAt: now, updatedAt: now)))

        try await reader.api.report(ReportRequest(targetType: .entry, targetId: entryId, reason: .spam))
        try await reader.api.report(ReportRequest(targetType: .entry, targetId: entryId, reason: .other))
        try await reader.api.block(profileId: writerProfile.id)
        try await reader.api.block(profileId: writerProfile.id)
        #expect(try await reader.api.blockedProfiles().map(\.id) == [writerProfile.id])
        try await reader.api.unblock(profileId: writerProfile.id)
        #expect(try await reader.api.blockedProfiles().isEmpty)

        try await writer.api.deleteAccount()
        #expect(!(try await writer.api.session().authenticated))
        let feed = try await reader.api.feed(limit: 30)
        #expect(!feed.entries.contains { $0.id == entryId })
        await #expect(throws: (any Error).self) { _ = try await reader.api.profile(handle: writerProfile.handle) }
    }

    /// A client can't choose where its entry sits in the feed: a future or unreadable
    /// `updatedAt` is stored as the server's now, and paging past it still works.
    @Test func entryTimestampsAreTheServers() async throws {
        let session = try await LiveContract.signedIn()
        let profile = try #require(try await session.api.session().bundle?.profile)
        let before = Date()
        let document = RichDocument.plain("Contract test: written in the future.")
        let ids = [Identifiers.make(), Identifiers.make()]
        for (id, stamp) in zip(ids, ["9999-12-31T00:00:00.000Z", "zzzz"]) {
            try await session.api.sync(.entry(JournalEntry(id: id, profileId: profile.id, entityId: Self.lithium, entityKind: .song, document: document, plainText: document.plainText, isPublic: true, createdAt: stamp, updatedAt: stamp)))
        }
        let stored = try #require(try await session.api.session().bundle).entries.filter { ids.contains($0.id) }
        #expect(stored.count == 2)
        for entry in stored {
            let updated = try #require(ResonoteDate.parse(entry.updatedAt))
            #expect(updated <= Date().addingTimeInterval(5))
            #expect(updated >= before.addingTimeInterval(-60))
            #expect(entry.createdAt <= entry.updatedAt)
        }
        // Every page's cursor opens the next page.
        let first = try await session.api.feed(limit: 1)
        let cursor = try #require(first.nextCursor)
        _ = try await session.api.feed(limit: 1, before: cursor)
        for id in ids { try await session.api.sync(.deleteEntry(id: id)) }
    }

    /// Network-dependent resolution paths (MusicBrainz, oEmbed). Recorded, not required.
    @Test func resolvesLinksAndIsrcs() async throws {
        let session = try await LiveContract.signedIn()
        let byLink = try await session.api.resolve(ResolveRequest(url: "https://open.spotify.com/track/4iV5W9uYEdYUVa79Axb7Rh"))
        #expect(byLink.track != nil)
        let byIsrc = try await session.api.resolve(ResolveRequest(track: NowPlayingTrack(title: "Paranoid Android", artist: "Radiohead", isrc: "GBAYE9700097", source: .manual, isPlaying: false)))
        #expect(byIsrc.confidence != .none)
    }
}

enum LiveContract {
    static let baseURL: URL? = ProcessInfo.processInfo.environment["RESONOTE_LIVE_BASE_URL"].flatMap(URL.init(string:))

    final class TokenBox: Sendable {
        let value = Mutex<String?>(nil)
    }

    static func signedIn() async throws -> (api: APIClient, token: TokenBoxAccess) {
        let base = try #require(baseURL)
        let box = TokenBox()
        let api = APIClient(baseURL: base, token: { box.value.withLock { $0 } })
        let email = "ios-contract-\(Identifiers.make().prefix(8))@example.com"
        let requested = try await api.requestCode(email: email)
        let code = try #require(requested.devCode, "The server must run without a mail provider so it returns devCode.")
        let verified = try await api.verify(email: email, code: code)
        let token = try #require(verified.token, "verify with client: ios must return a bearer token")
        #expect(verified.bundle != nil)
        box.value.withLock { $0 = token }
        return (api, TokenBoxAccess(box: box))
    }

    struct TokenBoxAccess: Sendable {
        let box: TokenBox
        func withLock(_ body: (inout String?) -> Void) { box.value.withLock { body(&$0) } }
    }
}
