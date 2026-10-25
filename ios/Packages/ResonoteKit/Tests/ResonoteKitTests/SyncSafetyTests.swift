import Foundation
import Synchronization
import Testing
@testable import ResonoteKit

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString).json")
}

private func tempDrafts() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "drafts-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private let listen = SyncOperation.listen(ListenLog(id: "l1", profileId: "", songId: "s1", moods: ["warm"], note: "The bridge.", listenedAt: "2026-10-24T12:00:00.000Z"))

/// Records what was sent, in order.
private final class Sent: Sendable {
    private let bodies = Mutex<[String]>([])
    func record(_ data: Data) { bodies.withLock { $0.append(String(decoding: data, as: UTF8.self)) } }
    var all: [String] { bodies.withLock { $0 } }
}

/// Fails the first `count` sends with `error`, then succeeds.
private final class FailFirst: Sendable {
    private let remaining: Mutex<Int>
    private let error: APIError
    init(_ count: Int, with error: APIError) {
        remaining = Mutex(count)
        self.error = error
    }
    func send() throws {
        let fail = remaining.withLock { value -> Bool in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
        if fail { throw error }
    }
}

@Suite struct OutboxOutageTests {
    /// A server outage says nothing about the write: it is never given up, however many
    /// launches (each sends at once) or attempts it takes.
    @Test(arguments: [
        APIError.server(status: 500, message: "D1_ERROR"),
        APIError.server(status: 502, message: "bad gateway"),
        APIError.server(status: 520, message: "server error"),
        APIError.notConfigured,
        APIError.decoding("not JSON"),
        APIError.server(status: 429, message: "slow down"),
        APIError.server(status: 408, message: "timeout"),
    ])
    func outageNeverDropsAWrite(error: APIError) async throws {
        let file = tempFile()
        for _ in 0..<20 {
            let launch = SyncOutbox(client: APIClient(token: { nil }), fileURL: file)
            await launch.setSendOverride { _ in throw error }
            if await launch.pendingCount == 0 { await launch.enqueue(listen, owner: "p1") }
            await launch.drain()
            #expect(await launch.pendingCount == 1)
        }
        let after = SyncOutbox(client: APIClient(token: { nil }), fileURL: file)
        #expect(await after.unconfirmedKeys == ["listen:l1"])
        await after.setSendOverride { _ in }
        await after.drain()
        #expect(await after.pendingCount == 0)
    }

    @Test func onlyADefinitive4xxTakesAWriteOut() {
        #expect(SyncOutbox.outcome(of: .server(status: 400, message: "No."), op: "entry") == .rejected("No.", status: 400))
        #expect(SyncOutbox.outcome(of: .server(status: 409, message: "Taken."), op: "collection") == .rejected("Taken.", status: 409))
        #expect(SyncOutbox.outcome(of: .server(status: 404, message: "Gone."), op: "delete-entry") == .sent)
        #expect(SyncOutbox.outcome(of: .server(status: 503, message: "x"), op: "entry") == .retry("x"))
        #expect(SyncOutbox.outcome(of: .server(status: 500, message: "x"), op: "entry") == .retry("x"))
        #expect(SyncOutbox.outcome(of: .unauthorized, op: "entry") == .unauthorized)
        #expect(SyncOutbox.outcome(of: .transport("offline"), op: "entry") == .retry(APIError.transport("offline").localizedDescription))
    }

    @Test func retryNowSkipsTheBackoff() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: tempFile())
        let failer = FailFirst(1, with: .server(status: 500, message: "down"))
        await outbox.setSendOverride { _ in try failer.send() }
        await outbox.enqueue(listen, owner: "p1")
        await outbox.drain()
        // Backing off (two seconds): a drain now leaves it waiting.
        await outbox.drain()
        #expect(await outbox.pendingCount == 1)
        await outbox.retryNow()
        await outbox.drain()
        #expect(await outbox.pendingCount == 0)
    }

    @Test func confirmationsReportEachSentWrite() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: tempFile())
        await outbox.setSendOverride { _ in }
        let confirmations = await outbox.confirmations()
        await outbox.enqueue(.deleteEntry(id: "e1"), owner: "p1")
        await outbox.drain()
        var iterator = confirmations.makeAsyncIterator()
        let confirmed = await iterator.next()
        #expect(confirmed == SyncOutbox.Confirmation(key: "entry:e1", op: "delete-entry"))
    }

    @Test func refusedWriteNamesItsOwner() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: tempFile())
        await outbox.setSendOverride { _ in throw APIError.server(status: 403, message: "Not yours.") }
        let failures = await outbox.failures()
        await outbox.enqueue(listen, owner: "p1")
        await outbox.drain()
        var iterator = failures.makeAsyncIterator()
        let failure = await iterator.next()
        #expect(failure?.owner == "p1")
        #expect(failure?.kind == .rejected(status: 403))
    }
}

@Suite struct OutboxHandoverTests {
    @Test func anotherPersonSigningInHandsBackWhatWasDropped() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: tempFile())
        await outbox.setSendOverride { _ in throw APIError.unauthorized }
        let document = RichDocument.plain("Words A wrote.")
        let entry = JournalEntry(id: "e1", profileId: "a", entityId: "s1", entityKind: .song, document: document, plainText: document.plainText, createdAt: "2026-10-24T12:00:00.000Z", updatedAt: "2026-10-24T12:00:00.000Z")
        await outbox.adopt(owner: "a")
        await outbox.pauseForSignIn()
        await outbox.enqueue(.entry(entry), owner: "a")
        #expect(await outbox.pendingCount(notOwnedBy: "b") == 1)
        #expect(await outbox.pendingCount(notOwnedBy: "a") == 0)
        let dropped = await outbox.adopt(owner: "b")
        #expect(dropped.map(\.op) == ["entry"])
        // Never sent (the queue was paused).
        #expect(dropped.first?.mayHaveReachedServer == false)
        #expect(dropped.first?.owner == "a")
        let body = String(decoding: dropped.first?.body ?? Data(), as: UTF8.self)
        #expect(body.contains("Words A wrote."))
        #expect(await outbox.pendingCount == 0)
    }

    @Test func signingOutHandsBackWhatWasQueued() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: tempFile())
        // A timeout: the request may have landed even though no answer came back.
        await outbox.setSendOverride { _ in throw APIError.transport("timed out") }
        await outbox.enqueue(listen, owner: "a")
        await outbox.drain()
        let removed = await outbox.clear()
        #expect(removed.map(\.key) == ["listen:l1"])
        #expect(removed.first?.mayHaveReachedServer == true)
        #expect(await outbox.pendingCount == 0)
    }
}

@Suite struct OutboxPinAfterDeleteTests {
    /// A pin waiting out its backoff must not be sent after its entry is deleted.
    @Test func deleteSupersedesAWaitingPin() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: tempFile())
        let sent = Sent()
        let failer = FailFirst(1, with: .transport("offline"))
        await outbox.setSendOverride { data in
            try failer.send()
            sent.record(data)
        }
        await outbox.enqueue(.pin(targetType: .entry, targetId: "e1", position: 0, pinned: true), owner: "p1")
        await outbox.drain()
        #expect(await outbox.unconfirmedKeys == ["pin:entry:e1"])
        await outbox.enqueue(.deleteEntry(id: "e1"), owner: "p1")
        await outbox.retryNow()
        await outbox.drain()
        #expect(await outbox.pendingCount == 0)
        let pins = sent.all.filter { $0.contains(#""op":"pin""#) }
        #expect(pins.count == 1)
        #expect(pins.allSatisfy { $0.contains(#""pinned":false"#) })
        #expect(!sent.all.contains { $0.contains(#""pinned":true"#) })
    }

    @Test func deleteWithoutAPinSendsNoUnpin() async throws {
        let outbox = SyncOutbox(client: APIClient(token: { nil }), fileURL: tempFile())
        let sent = Sent()
        await outbox.setSendOverride { sent.record($0) }
        await outbox.enqueue(.deleteCollection(id: "c1"), owner: "p1")
        await outbox.drain()
        #expect(sent.all.count == 1)
    }
}

@Suite struct DraftOwnershipTests {
    @Test func oneAccountsDraftsAreHiddenFromTheNext() throws {
        let root = tempDrafts()
        let a = DraftStore(directory: root, owner: "a")
        let b = DraftStore(directory: root, owner: "b")
        a.append("A's private words.", lenses: [], isPublic: false, kind: .song, entityId: "s1")
        #expect(b.load(key: "song-s1") == nil)
        #expect(b.all().isEmpty)
        b.append("B's words.", lenses: [], isPublic: true, kind: .song, entityId: "s1")
        // Same song, separate drafts.
        #expect(a.load(key: "song-s1")?.document.plainText == "A's private words.")
        #expect(b.load(key: "song-s1")?.document.plainText == "B's words.")
        b.delete(key: "song-s1")
        #expect(a.load(key: "song-s1") != nil)
    }

    @Test func unownedDraftsAreClaimedBySaving() throws {
        let root = tempDrafts()
        let unowned = DraftStore(directory: root)
        unowned.append("Written while signed out.", lenses: [], isPublic: true, kind: .song, entityId: "s1")
        let a = DraftStore(directory: root, owner: "a")
        #expect(a.all().count == 1)
        a.append("More.", lenses: [], isPublic: true, kind: .song, entityId: "s1")
        #expect(unowned.load(key: "song-s1") == nil)
        let draft = try #require(a.load(key: "song-s1"))
        #expect(draft.document.plainText.contains("Written while signed out."))
        #expect(draft.document.plainText.contains("More."))
        #expect(DraftStore(directory: root, owner: "b").all().isEmpty)
    }

    @Test func retractTakesBackOnlyThoseWords() throws {
        let store = DraftStore(directory: tempDrafts(), owner: "a")
        store.append("Earlier thought.", lenses: [], isPublic: true, kind: .song, entityId: "s1")
        store.append("Autosaved\nwords.", lenses: [], isPublic: true, kind: .song, entityId: "s1")
        store.retract("Autosaved\nwords.", fromKey: "song-s1")
        #expect(store.load(key: "song-s1")?.document.plainText == "Earlier thought.")
        store.retract("Earlier thought.", fromKey: "song-s1")
        #expect(store.load(key: "song-s1") == nil)
        // Words that aren't there change nothing.
        store.append("Kept.", lenses: [], isPublic: true, kind: .song, entityId: "s2")
        store.retract("Something else.", fromKey: "song-s2")
        #expect(store.load(key: "song-s2")?.document.plainText == "Kept.")
    }
}

@Suite struct CatalogBoundTests {
    @Test func prunedKeepsTheJournalItsNeedsAndTheMostRecent() throws {
        var index = CatalogIndex()
        index.absorb(CatalogSlice(
            artists: [Artist(id: "ar-kept", name: "Kept", slug: "kept")],
            albums: [Album(id: "al-kept", name: "Kept album", slug: "kept-album", artistId: "ar-kept")],
            songs: [Song(id: "s-kept", name: "Kept song", slug: "kept-song", artistId: "ar-kept", albumId: "al-kept")],
            genres: [Genre(id: "g1", name: "Shoegaze", slug: "shoegaze")]
        ))
        for number in 0..<50 {
            index.absorb(CatalogSlice(artists: [Artist(id: "ar-\(number)", name: "Artist \(number)", slug: "a\(number)")]))
        }
        index.absorb(CatalogSlice(songs: [Song(id: "s-new", name: "New", slug: "new", artistId: "ar-0")]))
        let pruned = index.pruned(keeping: ["s-kept"], limit: 3)
        #expect(pruned.songs["s-kept"] != nil)
        #expect(pruned.albums["al-kept"] != nil)
        #expect(pruned.artists["ar-kept"] != nil)
        #expect(pruned.genres["g1"] != nil)
        // The three most recent other rows, plus what they need (s-new's artist).
        #expect(pruned.songs["s-new"] != nil)
        #expect(pruned.artists["ar-49"] != nil)
        #expect(pruned.artists["ar-48"] != nil)
        #expect(pruned.artists["ar-0"] != nil)
        #expect(pruned.artists["ar-1"] == nil)
        #expect(pruned.count == 8)
        // Recency survives the file.
        let decoded = try JSONDecoder().decode(CatalogIndex.self, from: JSONEncoder().encode(pruned))
        #expect(decoded == pruned)
        #expect(decoded.pruned(keeping: [], limit: 1).songs["s-new"] != nil)
    }
}

@Suite struct ExternalWriteTests {
    @Test func aShareSaveAfterTheLastReadIsNoticed() throws {
        let defaults = try #require(UserDefaults(suiteName: "resonote-tests-\(UUID().uuidString)"))
        let read = Date()
        #expect(!ExternalWrites.happened(after: read, in: defaults))
        ExternalWrites.mark(at: read.addingTimeInterval(5), in: defaults)
        #expect(ExternalWrites.happened(after: read, in: defaults))
        #expect(!ExternalWrites.happened(after: read.addingTimeInterval(10), in: defaults))
        #expect(ExternalWrites.happened(after: nil, in: defaults))
    }
}
