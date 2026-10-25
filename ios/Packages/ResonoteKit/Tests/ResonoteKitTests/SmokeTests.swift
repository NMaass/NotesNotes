import Foundation
import Testing
@testable import ResonoteKit

@Suite struct ModelDecodingTests {
    @Test func decodesWebEntryShape() throws {
        let json = """
        {"id":"e1","profileId":"p1","entityId":"40000000-0000-0000-0000-000000000001","entityKind":"song",
         "document":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hello "},
           {"type":"musicReference","attrs":{"referenceId":"r1","id":"s2","label":"When You Sleep","entityKind":"song","relation":"reminds-me-of","lenses":["production","nope"]}}]}]},
         "plainText":"Hello When You Sleep","lenses":["feeling","unknown-lens"],
         "references":[{"id":"r1","entityId":"s2","entityKind":"song","label":"When You Sleep","relation":"reminds-me-of","lenses":["production"]}],
         "public":true,"createdAt":"2026-10-24 12:00:00","updatedAt":"2026-10-24T12:00:00.000Z"}
        """
        let entry = try JSONDecoder().decode(JournalEntry.self, from: Data(json.utf8))
        #expect(entry.lenses == [.feeling])
        #expect(entry.references.first?.relation == .remindsMeOf)
        #expect(entry.isPublic)
        #expect(ResonoteDate.parse(entry.createdAt) != nil)
        #expect(ResonoteDate.parse(entry.updatedAt) != nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        #expect(encoded?["public"] as? Bool == true)
    }

    @Test func decodesCatalogEntityByKind() throws {
        let json = #"{"id":"a1","kind":"album","name":"Nevermind","slug":"nevermind","artistId":"x","year":1991}"#
        let entity = try JSONDecoder().decode(CatalogEntity.self, from: Data(json.utf8))
        #expect(entity.kind == .album)
        let roundTrip = try JSONDecoder().decode(CatalogEntity.self, from: JSONEncoder().encode(entity))
        #expect(roundTrip == entity)
    }

    @Test func syncOperationEncodesWebPayload() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncOperation.genreAssertion(entityId: "s", entityKind: .song, genreId: "g", asserted: true))) as? [String: Any]
        #expect(object?["op"] as? String == "genre-assertion")
        #expect(object?["asserted"] as? Bool == true)
    }

    @Test func deepLinksRoundTrip() {
        let links: [DeepLink] = [.capture(CapturePreset(lens: .production, mood: "warm", origin: "widget")), .identify(key: nil), .identify(key: "abc"), .write(kind: .song, id: "abc"), .entity(kind: .album, id: "mb-album-1"), .profile(handle: "maya"), .sharedLink("https://open.spotify.com/track/1?si=2")]
        for link in links { #expect(DeepLink(url: link.url) == link) }
    }

    @Test func trackTextMatchesAcrossServices() {
        #expect(TrackText.matchKey(artist: "Nirvana", title: "Lithium - Remastered 2011") == TrackText.matchKey(artist: "Nirvana", title: "Lithium"))
        #expect(TrackText.matchKey(artist: "Daft Punk feat. Pharrell Williams", title: "Get Lucky (feat. Pharrell Williams)") == TrackText.matchKey(artist: "Daft Punk", title: "Get Lucky"))
        #expect(TrackText.matchKey(artist: "Nirvana", title: "Lithium (Live)") != TrackText.matchKey(artist: "Nirvana", title: "Lithium"))
        #expect(TrackText.fold("Sigur Rós") == "sigur ros")
    }
}

@Suite struct SyncOutboxTests {
    actor Recorder {
        var bodies: [String] = []
        func record(_ data: Data) { bodies.append(String(decoding: data, as: UTF8.self)) }
    }

    @Test func latestIntentWinsForPendingWrites() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).json")
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: file)
        let recorder = Recorder()
        await outbox.setSendOverride { data in
            await recorder.record(data)
        }
        await outbox.enqueue(.like(id: "l1", entityId: "s1", entityKind: .song, clientVersion: 1, liked: true))
        await outbox.enqueue(.like(id: "l1", entityId: "s1", entityKind: .song, clientVersion: 2, liked: false))
        await outbox.drain()
        try await Task.sleep(for: .milliseconds(50))
        let bodies = await recorder.bodies
        #expect(bodies.last?.contains(#""liked":false"#) == true)
        #expect(await outbox.pendingCount == 0)
    }

    /// A session read that started before a write was confirmed must not drop it.
    @Test func checkpointKeepsWritesConfirmedDuringARead() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).json")
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: file)
        await outbox.setSendOverride { _ in }
        await outbox.enqueue(.deleteEntry(id: "before"))
        let checkpoint = await outbox.checkpoint()
        await outbox.enqueue(.like(id: "l1", entityId: "s1", entityKind: .song, clientVersion: 1, liked: true))
        await outbox.drain()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await outbox.unconfirmedKeys.isEmpty)
        let kept = await outbox.keysToKeepLocal(since: checkpoint)
        #expect(kept == ["entry:before", "like:s1"])
        let later = await outbox.checkpoint()
        #expect(await outbox.keysToKeepLocal(since: later).isEmpty)
    }
}

@Suite struct SyncOutboxDurabilityTests {
    private static func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).json")
    }

    /// A gate the send override waits on, so a test can hold a write "in flight".
    actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    @Test func writeInFlightIsStillOnDisk() async throws {
        let file = Self.tempFile()
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: file)
        let gate = Gate()
        await outbox.setSendOverride { _ in await gate.wait() }
        await outbox.enqueue(.deleteEntry(id: "e1"), owner: "p1")
        try await Task.sleep(for: .milliseconds(50))
        // The app is killed here: a fresh outbox reading the same file still has the write.
        let relaunched = SyncOutbox(client: APIClient(token: { nil }), fileURL: file)
        #expect(await relaunched.unconfirmedKeys == ["entry:e1"])
        await gate.release()
        await outbox.drain()
        #expect(await outbox.pendingCount == 0)
    }

    @Test func failingWriteDoesNotBlockOthers() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: Self.tempFile())
        await outbox.setSendOverride { data in
            if String(decoding: data, as: UTF8.self).contains("\"bad\"") {
                throw APIError.server(status: 500, message: "UNIQUE constraint failed")
            }
        }
        await outbox.enqueue(.deleteEntry(id: "bad"), owner: "p1")
        await outbox.enqueue(.like(id: "l1", entityId: "s1", entityKind: .song, clientVersion: 1, liked: true), owner: "p1")
        await outbox.drain()
        #expect(await outbox.unconfirmedKeys == ["entry:bad"])
    }

    @Test func refusedWriteIsReportedWithItsPayload() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: Self.tempFile())
        await outbox.setSendOverride { _ in throw APIError.server(status: 400, message: "No.") }
        let failures = await outbox.failures()
        await outbox.enqueue(.deleteCollection(id: "c1"), owner: "p1")
        await outbox.drain()
        var iterator = failures.makeAsyncIterator()
        let failure = await iterator.next()
        #expect(failure?.kind == .rejected(status: 400))
        #expect(failure?.op == "delete-collection")
        #expect(failure?.body != nil)
        #expect(await outbox.pendingCount == 0)
    }

    @Test func expiredSessionKeepsWritesForTheSamePerson() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: Self.tempFile())
        await outbox.setSendOverride { _ in throw APIError.unauthorized }
        await outbox.enqueue(.listen(ListenLog(id: "x", profileId: "", songId: "s", moods: [], listenedAt: "2026-10-24T12:00:00.000Z")), owner: "p1")
        await outbox.drain()
        #expect(await outbox.isPausedForSignIn)
        #expect(await outbox.pendingCount == 1)
        await outbox.setSendOverride { _ in }
        #expect(await outbox.adopt(owner: "p1").isEmpty)
        await outbox.drain()
        #expect(await outbox.pendingCount == 0)
    }

    @Test func anotherPersonNeverSendsThePreviousOwnersWrites() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: Self.tempFile())
        await outbox.setSendOverride { _ in throw APIError.unauthorized }
        await outbox.enqueue(.profile(displayName: "A", bio: "", avatarUrl: nil, profileSongId: nil, genreIds: []), owner: "a")
        await outbox.drain()
        #expect(await outbox.adopt(owner: "b").count == 1)
        #expect(await outbox.pendingCount == 0)
    }

    @Test func clearedWriteInFlightIsNeverPutBack() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: Self.tempFile())
        let gate = Gate()
        await outbox.setSendOverride { _ in
            await gate.wait()
            throw APIError.transport("offline")
        }
        await outbox.enqueue(.profile(displayName: "A", bio: "", avatarUrl: nil, profileSongId: nil, genreIds: []), owner: "a")
        try await Task.sleep(for: .milliseconds(50))
        await outbox.clear()
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await outbox.pendingCount == 0)
    }

    @Test func deletingSomethingAlreadyGoneCountsAsDone() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: Self.tempFile())
        await outbox.setSendOverride { _ in throw APIError.server(status: 404, message: "Entry not found.") }
        await outbox.enqueue(.deleteEntry(id: "e1"), owner: "p1")
        await outbox.drain()
        #expect(await outbox.pendingCount == 0)
    }
}

@Suite struct NowPlayingClaimTests {
    @Test func oneTimeReportsStopClaimingPlayback() {
        let start = Date()
        let shazam = NowPlayingTrack(title: "Lithium", artist: "Nirvana", source: .shazam, isPlaying: true, observedAt: ResonoteDate.string(from: start))
        #expect(shazam.claimsPlayback(at: start.addingTimeInterval(60)))
        #expect(!shazam.claimsPlayback(at: start.addingTimeInterval(NowPlayingTrack.assumedSongLength + 1)))
        let timed = NowPlayingTrack(title: "Lithium", artist: "Nirvana", durationMs: 120_000, source: .manual, isPlaying: true, observedAt: ResonoteDate.string(from: start))
        #expect(!timed.claimsPlayback(at: start.addingTimeInterval(121)))
        let link = NowPlayingTrack(title: "Lithium", artist: "Nirvana", source: .link, isPlaying: false, observedAt: ResonoteDate.string(from: start))
        #expect(!link.claimsPlayback(at: start))
        let live = NowPlayingTrack(title: "Lithium", artist: "Nirvana", source: .lastfm, isPlaying: true, observedAt: ResonoteDate.string(from: start))
        #expect(live.claimsPlayback(at: start.addingTimeInterval(9 * 60)))
        #expect(!live.claimsPlayback(at: start.addingTimeInterval(11 * 60)))
    }

    @Test func identifyLinksCarryTheInstallKey() {
        #expect(DeepLink(url: DeepLink.identify(key: "k1").url) == .identify(key: "k1"))
        #expect(!IdentifyKey.matches(nil))
        #expect(IdentifyKey.matches(IdentifyKey.current))
    }
}

@Suite struct CatalogIndexTests {
    @Test func absorbReportsOnlyRealChanges() {
        var index = CatalogIndex()
        let album = Album(id: "al1", name: "Nevermind", slug: "nevermind", artistId: "ar1", imageUrl: "https://b")
        let first = index.absorb(CatalogSlice(albums: [album]))
        #expect(first)
        #expect(!index.adds(CatalogSlice(albums: [album])))
        let again = index.absorb(CatalogSlice(albums: [album]))
        #expect(!again)
        let artist = CatalogEntity.artist(Artist(id: "ar1", name: "Nirvana", slug: "nirvana"))
        #expect(index.artworkURL(for: artist) == "https://b")
        index.absorb(CatalogSlice(albums: [Album(id: "al2", name: "Bleach", slug: "bleach", artistId: "ar1", imageUrl: "https://a")]))
        #expect(index.artworkURL(for: artist) == "https://a")
        let decoded = try? JSONDecoder().decode(CatalogIndex.self, from: JSONEncoder().encode(index))
        #expect(decoded?.artworkURL(for: artist) == "https://a")
    }
}

@Suite struct ContractExtensionTests {
    @Test func entityDetailReadsOptionalTagCount() throws {
        let genre = #"{"entity":{"id":"g1","kind":"genre","name":"Shoegaze","slug":"shoegaze"},"albums":[],"tracks":[],"genres":[],"credits":[],"facts":[],"entries":[],"authors":[],"connections":[]"#
        let withCount = try JSONDecoder().decode(EntityDetail.self, from: Data((genre + #","tagCount":12}"#).utf8))
        #expect(withCount.tagCount == 12)
        let without = try JSONDecoder().decode(EntityDetail.self, from: Data((genre + "}").utf8))
        #expect(without.tagCount == nil)
    }

    @Test func deepLinkURLsAlwaysParseBack() {
        let link = DeepLink.entity(kind: .song, id: "with space/and slash")
        #expect(link.url.scheme == DeepLink.scheme)
        #expect(DeepLink(url: DeepLink.capture(CapturePreset()).url) == .capture(CapturePreset()))
    }

    @Test func appendingToADraftNeverReplacesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = DraftStore(directory: directory)
        store.append("  First thought.  ", lenses: [.feeling], isPublic: false, kind: .song, entityId: "s1")
        store.append("Second thought.", lenses: [.feeling, .production], isPublic: true, kind: .song, entityId: "s1")
        store.append("   ", lenses: [.context], isPublic: true, kind: .song, entityId: "s1")
        let draft = try #require(store.load(key: Draft.key(kind: .song, entityId: "s1", entryId: nil)))
        #expect(draft.document.plainText.contains("First thought."))
        #expect(draft.document.plainText.contains("Second thought."))
        #expect(draft.lenses == [.feeling, .production])
        #expect(draft.isPublic == false)
    }
}

@Suite struct UnmatchedDraftTests {
    @Test func unmatchedWordsFollowTheSongOnceMatched() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = DraftStore(directory: directory)
        let track = NowPlayingTrack(title: "Lithium", artist: "Nirvana", source: .shazam, isPlaying: false)
        store.appendUnmatched("The bass line.", lenses: [.production], isPublic: false, track: track)
        #expect(store.unmatched(for: track)?.isUnmatched == true)
        store.append("Earlier words.", lenses: [], isPublic: true, kind: .song, entityId: "s1")
        #expect(store.attachUnmatched(track, toSong: "s1"))
        #expect(store.unmatched(for: track) == nil)
        let draft = try #require(store.load(key: Draft.key(kind: .song, entityId: "s1", entryId: nil)))
        #expect(draft.document.plainText.contains("Earlier words."))
        #expect(draft.document.plainText.contains("The bass line."))
        #expect(draft.isPublic == false)
        #expect(store.recent(limit: 5) { _ in true }.count == 1)
    }
}
