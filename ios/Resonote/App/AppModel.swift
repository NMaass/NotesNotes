import Network
import ResonoteKit
import SwiftUI
import UIKit

/// The signed-in person's data and every write they make.
///
/// Writes are optimistic: the local bundle changes immediately, then the durable
/// `SyncOutbox` delivers them per object with the latest intent winning. A server
/// refresh never reverts a write that is still unconfirmed, and nothing the person
/// wrote is thrown away unless they sign out on purpose: an expired session keeps the
/// bundle and the queue until the same person signs in again. When writes do leave the
/// queue unsent (a sign-out, another person signing in, a refusal), the words they
/// carried go back to their writer's drafts.
@Observable
final class AppModel {
    let api: APIClient
    let outbox: SyncOutbox

    /// The owner's bundle (includes private listens and entries). `nil` when signed out.
    private(set) var bundle: ProfileBundle?
    /// Every catalog row seen on this device.
    private(set) var catalog = CatalogIndex()
    /// Bumped whenever `catalog` changes, for memoized work that depends on it.
    private(set) var catalogRevision = 0

    // Lookups derived from the bundle once per change, so reads in view bodies are
    // set and dictionary hits, and a Like only touches readers of `likedIds`.
    private(set) var likedIds: Set<String> = []
    private(set) var pinKeys: Set<String> = []
    private(set) var assertionKeys: Set<String> = []
    private(set) var entriesById: [String: JournalEntry] = [:]
    /// The owner's entries per entity, newest edit first.
    private(set) var entriesByEntity: [String: [JournalEntry]] = [:]
    /// Lenses and moods this person reaches for most, padded with defaults.
    private(set) var habits = AppModel.habits(entries: [], listens: [])

    /// True until the session cached on this device has been read at launch.
    private(set) var isRestoringSession = true
    /// The server stopped accepting this device's session. The bundle and every unsent
    /// write stay until the same person signs in again.
    private(set) var sessionExpired = false
    /// Writes still waiting on this device, while the session is expired.
    private(set) var unsyncedWrites = 0

    /// People whose writing this person chose not to see, everywhere in the app.
    private(set) var blockedProfiles: [Profile] = []
    private(set) var blockedIds: Set<String> = []

    /// The signed-in profile's id; drafts are read and written in its scope.
    private(set) var ownerId: String?

    /// The most recent write the server refused or could not take, shown quietly.
    var syncNotice: String?
    var isSignInPresented = false

    @ObservationIgnored private let token: SessionToken
    @ObservationIgnored private var pendingIntent: (() -> Void)?
    /// The intent to resume once the sign-in sheet has finished leaving.
    @ObservationIgnored private var resumeIntent: (() -> Void)?
    @ObservationIgnored private var pendingSaves: Set<SessionFiles.File> = []
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    /// Every outbox mutation from this model, in order: two quick taps reach the queue in the order they were made.
    @ObservationIgnored private var writeChain: Task<Void, Never>?
    @ObservationIgnored private var cacheLoad: Task<Void, Never>?
    /// Bumped by sign-in and sign-out, so a read that started before either is discarded.
    @ObservationIgnored private var sessionGeneration = 0
    /// Someone signed out, or a different person's session replaced theirs. Set by
    /// `NowPlayingService`, which forgets the previous person's Last.fm link.
    @ObservationIgnored var onAccountChange: (() -> Void)?
    /// Local writes by revision, so a refresh can keep objects written while it was in flight.
    @ObservationIgnored private var localRevision = 0
    @ObservationIgnored private var localWrites: [(revision: Int, key: String)] = []
    @ObservationIgnored private var lastRefresh: Date?
    /// Entry ids the server had in the last bundle it sent, to tell edits from new entries.
    @ObservationIgnored private var serverEntryIds: Set<String> = []
    @ObservationIgnored private var reslugTried: [String: Set<String>] = [:]
    @ObservationIgnored private var widgetFacts: WidgetFacts?
    /// Song ids written about most recently, for the widget's "something new to say?".
    @ObservationIgnored private var recentlyNotedSongIds: [String] = []
    @ObservationIgnored private var backgroundSync: UIBackgroundTaskIdentifier = .invalid
    /// Bumped by each background task, so a sync that outlives its task never ends a newer one.
    @ObservationIgnored private var backgroundSyncGeneration = 0
    /// Block changes the server hasn't confirmed yet: profile id → blocked.
    @ObservationIgnored private var pendingBlocks: [String: Bool] = [:]
    /// The profile `blockedProfiles` and `pendingBlocks` belong to; they're only ever sent with its session.
    @ObservationIgnored private var blocksOwner: String?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkAvailable = true

    private static let bundleFile = "bundle.json"
    private static let catalogFile = "catalog.json"
    private static let blocksFile = "blocks.json"
    private static let localWriteLimit = 200
    private static let refreshFreshFor: TimeInterval = 90
    /// Catalog rows kept on disk beyond the person's own journal, most recently seen first.
    private static let catalogCacheLimit = 2_000

    var isSignedIn: Bool { bundle != nil }
    /// Signed in with a session the server still accepts, so account reads and matching can work.
    var hasLiveSession: Bool { bundle != nil && !sessionExpired }
    var profile: Profile? { bundle?.profile }

    /// The signed-in person's drafts (plus any written while nobody was signed in).
    var drafts: DraftStore { DraftStore.shared.scoped(to: ownerId) }
    /// Bumped when a written-first note attaches a song on its own, so the Drafts list
    /// reads again without waiting for the next visit.
    private(set) var writtenNotesAttached = 0

    init() {
        let token = SessionToken()
        self.token = token
        api = APIClient(baseURL: AppGroup.apiBaseURL, token: { token.read() })
        outbox = SyncOutbox(client: api)
        cacheLoad = Task { await self.restoreCachedSession() }
        Task { await self.watchSyncFailures() }
        Task { await self.watchConfirmations() }
        watchNetwork()
    }

    // MARK: Session

    /// Runs `intent` now if signed in; otherwise asks to sign in and runs it afterward,
    /// so the person keeps their place (the web's `requireAuth`).
    func requireAuth(_ intent: @escaping () -> Void) {
        if isSignedIn {
            intent()
        } else {
            pendingIntent = intent
            isSignInPresented = true
        }
    }

    /// Shows sign-in for a session that expired; nothing waits on it but the queue.
    func renewSession() {
        isSignInPresented = true
    }

    /// Returns once the session cached on this device has been read at launch.
    func waitUntilRestored() async {
        await cacheLoad?.value
    }

    /// How many changes made on this device by the person signed in now (or whose session
    /// expired) signing in as `profileId` would remove, so sign-in can ask first. Their
    /// unpublished words would still go to their own drafts.
    func unsyncedChangesLost(signingInAs profileId: String) async -> Int {
        guard let current = bundle, current.profile.id != profileId else { return 0 }
        await writesAreQueued()
        let queued = await outbox.pendingCount(notOwnedBy: profileId)
        return queued + pendingBlocks.count
    }

    /// Stores the session and resumes what the person was doing. When the sign-in
    /// sheet is up, the intent waits until it has left (`signInSheetDidDismiss`), so
    /// an intent that presents a sheet never collides with the one going away.
    func completeSignIn(token newToken: String, bundle fresh: ProfileBundle) {
        token.save(newToken)
        sessionGeneration += 1
        let generation = sessionGeneration
        let mark = localRevision
        let owner = fresh.profile.id
        if let current = bundle, current.profile.id == owner {
            // The same person after an expired session: their unsent writes stay and go out now.
            enqueueOnChain { outbox in
                let unconfirmed = await outbox.unconfirmedKeys
                await MainActor.run {
                    guard generation == self.sessionGeneration else { return }
                    self.apply(serverBundle: fresh, unconfirmed: unconfirmed.union(self.localKeys(since: mark)))
                }
                await outbox.adopt(owner: owner)
                await outbox.retryNow()
            }
        } else {
            // Someone new on this device: their bundle and blocks replace everything. What
            // the previous person left unsent leaves the queue, and its words go to their drafts.
            handOver(to: fresh)
        }
        sessionExpired = false
        unsyncedWrites = 0
        lastRefresh = Date()
        Task { await syncBlocks() }
        let intent = pendingIntent
        pendingIntent = nil
        if isSignInPresented {
            resumeIntent = intent
            isSignInPresented = false
        } else {
            intent?()
        }
    }

    func cancelSignIn() {
        pendingIntent = nil
        resumeIntent = nil
        isSignInPresented = false
    }

    /// Called by the sign-in sheet's presenter once its dismissal has finished.
    func signInSheetDidDismiss() {
        let intent = resumeIntent
        resumeIntent = nil
        intent?()
    }

    /// Reloads the owner's bundle, keeping any local writes the server has not confirmed.
    /// - Parameter force: skip the freshness window (pull to refresh, sign-in screens).
    func refreshSession(force: Bool = true) async {
        await cacheLoad?.value
        // A save from the share sheet since the last read is worth reading again at once.
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshFreshFor,
           !ExternalWrites.happened(after: lastRefresh) { return }
        guard token.read() != nil else {
            // No token but a cached journal: the keychain may be locked or the item gone. Keep everything.
            if bundle != nil { markSessionExpired() }
            return
        }
        let generation = sessionGeneration
        let mark = localRevision
        let started = Date()
        do {
            // Taken before the read: a write confirmed while it is in flight may be missing from it.
            let checkpoint = await outbox.checkpoint()
            let response = try await api.session()
            guard generation == sessionGeneration else { return }
            guard response.authenticated, let fresh = response.bundle else {
                markSessionExpired()
                return
            }
            let unconfirmed = await outbox.keysToKeepLocal(since: checkpoint)
            guard generation == sessionGeneration else { return }
            if let current = bundle, current.profile.id != fresh.profile.id {
                handOver(to: fresh)
            } else {
                apply(serverBundle: fresh, unconfirmed: unconfirmed.union(localKeys(since: mark)))
                let owner = fresh.profile.id
                // The server just answered: anything waiting out a backoff goes now.
                enqueueOnChain { outbox in
                    await outbox.adopt(owner: owner)
                    await outbox.retryNow()
                }
            }
            sessionExpired = false
            unsyncedWrites = 0
            lastRefresh = started
            await syncBlocks()
        } catch APIError.unauthorized {
            guard generation == sessionGeneration else { return }
            markSessionExpired()
        } catch {
            // Offline or the server is unwell: keep the cached bundle.
        }
    }

    /// Signs out on purpose (the person confirmed it): ends the session on the server
    /// with the token it was made with, then forgets this device's copy and its queue.
    /// Their drafts stay on this device, out of sight until they sign in again, and so do
    /// the words of entries and listen notes that hadn't reached the server.
    func signOut() {
        if let current = token.read() {
            let client = APIClient(baseURL: api.baseURL, token: { current })
            Task { try? await client.signOut() }
        }
        clearLocalSession(keepingWords: true)
    }

    /// Ends a session that was just made but won't be used (sign-in was cancelled).
    func discardSession(token unused: String) {
        let client = APIClient(baseURL: api.baseURL, token: { unused })
        Task { try? await client.signOut() }
    }

    /// Deletes the account and everything it made on the server, then this device's copy.
    func deleteAccount() async throws {
        try await api.deleteAccount()
        let drafts = drafts
        for draft in drafts.all() { drafts.delete(key: draft.key) }
        clearLocalSession(keepingWords: false)
    }

    private func markSessionExpired() {
        guard bundle != nil else { return }
        if !sessionExpired { sessionExpired = true }
        enqueueOnChain { outbox in
            await outbox.pauseForSignIn()
            let count = await outbox.pendingCount
            await MainActor.run { self.unsyncedWrites = count }
        }
    }

    private func clearLocalSession(keepingWords: Bool) {
        token.delete()
        sessionGeneration += 1
        let previous = bundle
        let published = serverEntryIds
        bundle = nil
        rebuildDerived(from: previous)
        serverEntryIds = []
        pendingIntent = nil
        resumeIntent = nil
        sessionExpired = false
        unsyncedWrites = 0
        lastRefresh = nil
        resetBlocks(for: nil)
        // Queued behind any write still in flight, so a late write can't bring the file back.
        scheduleSave(.bundle)
        let owner = previous?.profile.id
        enqueueOnChain { outbox in
            let removed = await outbox.clear()
            guard keepingWords, !removed.isEmpty else { return }
            await MainActor.run { self.keepWords(from: removed, publishedEntryIds: published, fallbackOwner: owner) }
        }
        publishWidgetFacts()
        onAccountChange?()
    }

    /// A different person's session replaces the one on this device: their bundle wins
    /// outright, the previous person's blocks are forgotten here (never sent with this
    /// session), and their unsent writes leave the queue with their words kept in their drafts.
    private func handOver(to fresh: ProfileBundle) {
        let previousOwner = bundle?.profile.id
        let published = serverEntryIds
        let owner = fresh.profile.id
        resetBlocks(for: owner)
        apply(serverBundle: fresh, unconfirmed: [])
        onAccountChange?()
        enqueueOnChain { outbox in
            let dropped = await outbox.adopt(owner: owner)
            if !dropped.isEmpty {
                await MainActor.run { self.keepWords(from: dropped, publishedEntryIds: published, fallbackOwner: previousOwner) }
            }
            await outbox.retryNow()
        }
    }

    /// Reads the session this device cached last time, off the main actor, and shows it
    /// in one batch. A sign-in that finished meanwhile is newer and wins.
    private func restoreCachedSession() async {
        async let cachedBundle = SharedFile.readInBackground(ProfileBundle.self, from: Self.bundleFile)
        async let cachedCatalog = SharedFile.readInBackground(CatalogIndex.self, from: Self.catalogFile)
        async let cachedBlocks = SharedFile.readInBackground(BlockCache.self, from: Self.blocksFile)
        let (restored, restoredCatalog, blocks) = await (cachedBundle, cachedCatalog, cachedBlocks)

        // Older rows first, so anything this launch already learned wins.
        var merged = restoredCatalog ?? CatalogIndex()
        if let restored { merged.absorb(restored.catalog) }
        merged.absorb(catalog)
        catalog = merged
        catalogRevision += 1

        if sessionGeneration == 0, bundle == nil, let restored {
            bundle = restored
            rebuildDerived(from: nil)
            serverEntryIds = Set(restored.entries.map(\.id))
            let owner = restored.profile.id
            // Blocks cached for someone else are never shown or sent with this session.
            if let blocks, blocks.owner == nil || blocks.owner == owner {
                blockedProfiles = blocks.profiles
                blockedIds = Set(blocks.profiles.map(\.id))
                pendingBlocks = blocks.pending
            }
            blocksOwner = owner
            enqueueOnChain { outbox in
                let dropped = await outbox.adopt(owner: owner, keepingUnowned: true)
                guard !dropped.isEmpty else { return }
                await MainActor.run { self.keepWords(from: dropped, publishedEntryIds: [], fallbackOwner: nil) }
            }
        }
        isRestoringSession = false
        publishWidgetFacts()
    }

    // MARK: Catalog

    func absorb(_ slice: CatalogSlice) {
        guard !slice.isEmpty, catalog.adds(slice) else { return }
        catalog.absorb(slice)
        catalogDidChange()
    }

    func absorb(_ entity: CatalogEntity) {
        guard catalog.adds(entity) else { return }
        catalog.absorb(entity)
        catalogDidChange()
    }

    func absorb(_ detail: EntityDetail) {
        if catalog.adds(detail) {
            catalog.absorb(detail)
            catalogDidChange()
        }
        remember(entries: detail.entries, profiles: detail.authors)
    }

    private func catalogDidChange() {
        catalogRevision += 1
        persistCatalog()
    }

    // MARK: Other people's writing seen this session

    /// Public entries and authors loaded by feeds, entity pages, and profiles, so an
    /// entry can open in full without another request.
    private(set) var seenEntries: [String: JournalEntry] = [:]
    private(set) var seenProfiles: [String: Profile] = [:]

    func remember(entries: [JournalEntry], profiles: [Profile]) {
        for entry in entries where seenEntries[entry.id] != entry { seenEntries[entry.id] = entry }
        for profile in profiles where seenProfiles[profile.id] != profile { seenProfiles[profile.id] = profile }
    }

    /// The owner's entry, or one seen elsewhere this session.
    func anyEntry(id: String) -> JournalEntry? {
        entry(id: id) ?? seenEntries[id]
    }

    func author(of entry: JournalEntry) -> Profile? {
        if entry.profileId == bundle?.profile.id { return bundle?.profile }
        return seenProfiles[entry.profileId]
    }

    // MARK: Reads over the owner's bundle

    func isLiked(_ entityId: String) -> Bool {
        likedIds.contains(entityId)
    }

    func isPinned(_ type: ProfilePin.TargetType, _ id: String) -> Bool {
        pinKeys.contains(Self.pinKey(type, id))
    }

    func hasAsserted(genreId: String, on entityId: String) -> Bool {
        assertionKeys.contains(Self.assertionKey(entityId, genreId))
    }

    func entries(about entityId: String) -> [JournalEntry] {
        entriesByEntity[entityId] ?? []
    }

    func entry(id: String) -> JournalEntry? {
        entriesById[id]
    }

    func isBlocked(_ profileId: String) -> Bool {
        blockedIds.contains(profileId)
    }

    // MARK: Writes

    /// Likes or unlikes. The end state is decided now, from what the person sees, so a
    /// tap made while signed out can't undo a like their account already has.
    func toggleLike(_ entity: CatalogEntity) {
        let wanted = !isLiked(entity.id)
        requireAuth { [self] in setLiked(entity, wanted) }
    }

    func setLiked(_ entity: CatalogEntity, _ liked: Bool) {
        guard var bundle else { return }
        let index = bundle.likes.firstIndex { $0.entityId == entity.id }
        guard liked != (index != nil) else { return }
        absorb(entity)
        if let index {
            let removed = bundle.likes.remove(at: index)
            commit(bundle, .like(id: removed.id, entityId: entity.id, entityKind: entity.kind, clientVersion: removed.clientVersion + 1, liked: false))
        } else {
            let like = Like(id: Identifiers.make(), profileId: bundle.profile.id, entityId: entity.id, entityKind: entity.kind, clientVersion: 1, createdAt: ResonoteDate.now())
            bundle.likes.append(like)
            commit(bundle, .like(id: like.id, entityId: entity.id, entityKind: entity.kind, clientVersion: like.clientVersion, liked: true))
        }
    }

    func toggleGenre(_ genreId: String, on entity: CatalogEntity) {
        let wanted = !hasAsserted(genreId: genreId, on: entity.id)
        requireAuth { [self] in setGenre(genreId, on: entity, asserted: wanted) }
    }

    func setGenre(_ genreId: String, on entity: CatalogEntity, asserted: Bool) {
        guard var bundle else { return }
        let index = bundle.genreAssertions.firstIndex { $0.entityId == entity.id && $0.genreId == genreId }
        guard asserted != (index != nil) else { return }
        if let index {
            bundle.genreAssertions.remove(at: index)
        } else {
            bundle.genreAssertions.append(EntityGenre(entityId: entity.id, entityKind: entity.kind, genreId: genreId, source: .user, createdBy: bundle.profile.id, votes: 1))
        }
        commit(bundle, .genreAssertion(entityId: entity.id, entityKind: entity.kind, genreId: genreId, asserted: asserted))
    }

    /// Saves a new or edited entry. Callers must already be signed in (the composer
    /// asks before publishing so the draft is never lost). Await `writesAreQueued()`
    /// before letting go of a draft that holds the same words.
    func save(_ entry: JournalEntry) {
        guard var bundle else { return }
        var entry = entry
        entry.profileId = bundle.profile.id
        if let index = bundle.entries.firstIndex(where: { $0.id == entry.id }) {
            bundle.entries[index] = entry
        } else {
            bundle.entries.insert(entry, at: 0)
        }
        commit(bundle, .entry(entry))
    }

    /// Write first, attach later: each written-first note takes the recent play that
    /// covers the moment it was begun, unless the person chose or detached its song.
    /// Drafts stay on the device; the entry is written (through `save`, so the sync
    /// queue) only when the person saves the note.
    func attachWrittenNotes(to plays: [RecentPlay]) {
        guard isSignedIn else { return }
        if !drafts.attachCoveringPlays(plays).isEmpty { writtenNotesAttached += 1 }
    }

    /// Saves a written-first note as a journal entry about `songId`, dated when it was
    /// written. Its draft goes once the write is safely in the sync queue.
    func saveWrittenNote(_ note: Draft, text: String, songId: String, lenses: [MusicLens], isPublic: Bool) {
        guard let bundle, note.isWrittenFirst else { return }
        let document = RichDocument.plain(text)
        let written = ResonoteDate.string(from: note.writtenAt ?? Date())
        save(JournalEntry(
            id: Identifiers.make(),
            profileId: bundle.profile.id,
            entityId: songId,
            entityKind: .song,
            document: document,
            plainText: document.plainText,
            lenses: lenses,
            references: [],
            isPublic: isPublic,
            createdAt: written,
            updatedAt: ResonoteDate.now()
        ))
        let drafts = drafts
        let key = note.key
        Task {
            await writesAreQueued()
            drafts.delete(key: key)
        }
    }

    func deleteEntry(id: String) {
        guard var bundle else { return }
        bundle.entries.removeAll { $0.id == id }
        bundle.pins.removeAll { $0.targetType == .entry && $0.targetId == id }
        commit(bundle, .deleteEntry(id: id))
    }

    @discardableResult
    func logListen(songId: String, moods: [String], note: String?) -> ListenLog? {
        guard var bundle else { return nil }
        let listen = ListenLog(id: Identifiers.make(), profileId: bundle.profile.id, songId: songId, moods: moods, note: note, listenedAt: ResonoteDate.now())
        bundle.listens.insert(listen, at: 0)
        commit(bundle, .listen(listen))
        return listen
    }

    @discardableResult
    func createCollection(name: String, description: String, isPublic: Bool = false) -> MusicCollection? {
        guard var bundle else { return nil }
        let now = ResonoteDate.now()
        let slug = Slug.unique(name, taken: Set(bundle.collections.map(\.slug)))
        let collection = MusicCollection(id: Identifiers.make(), profileId: bundle.profile.id, name: name, slug: slug, description: description, isPublic: isPublic, items: [], createdAt: now, updatedAt: now)
        bundle.collections.append(collection)
        commit(bundle, .collection(collection))
        return collection
    }

    func updateCollection(_ collection: MusicCollection) {
        guard var bundle, let index = bundle.collections.firstIndex(where: { $0.id == collection.id }) else { return }
        var updated = collection
        updated.items = updated.items.enumerated().map { offset, item in
            var item = item
            item.position = offset
            return item
        }
        updated.updatedAt = ResonoteDate.now()
        bundle.collections[index] = updated
        commit(bundle, .collection(updated))
    }

    func add(_ entity: CatalogEntity, toCollection collectionId: String, note: String? = nil) {
        guard var collection = bundle?.collections.first(where: { $0.id == collectionId }),
              !collection.items.contains(where: { $0.entityId == entity.id }) else { return }
        absorb(entity)
        collection.items.append(CollectionItem(id: Identifiers.make(), entityId: entity.id, entityKind: entity.kind, note: note, position: collection.items.count))
        updateCollection(collection)
    }

    func removeItem(_ itemId: String, fromCollection collectionId: String) {
        guard var collection = bundle?.collections.first(where: { $0.id == collectionId }) else { return }
        collection.items.removeAll { $0.id == itemId }
        updateCollection(collection)
    }

    func deleteCollection(id: String) {
        guard var bundle else { return }
        bundle.collections.removeAll { $0.id == id }
        bundle.pins.removeAll { $0.targetType == .collection && $0.targetId == id }
        commit(bundle, .deleteCollection(id: id))
    }

    // MARK: Publishing

    /// Publishes or unpublishes one of the owner's entries. The caller passes the end state
    /// the person chose at tap time (see `toggleLike`), so the last tap wins. It is not an
    /// edit to the writing, so `updatedAt` (and feed order) stays put. An unpublished edit
    /// of the entry follows the new choice, so saving that draft later never undoes it.
    func setPublished(entryId: String, _ published: Bool) {
        guard var bundle, let index = bundle.entries.firstIndex(where: { $0.id == entryId }) else { return }
        let current = bundle.entries[index]
        let key = Draft.key(kind: current.entityKind, entityId: current.entityId, entryId: current.id)
        if var draft = drafts.load(key: key), draft.isPublic != published {
            draft.isPublic = published
            draft.updatedAt = Date()
            drafts.save(draft)
        }
        guard current.isPublic != published else { return }
        bundle.entries[index].isPublic = published
        commit(bundle, .entry(bundle.entries[index]))
    }

    /// Publishes or unpublishes one of the owner's collections, like `setPublished(entryId:_:)`.
    func setPublished(collectionId: String, _ published: Bool) {
        guard var bundle, let index = bundle.collections.firstIndex(where: { $0.id == collectionId }),
              bundle.collections[index].isPublic != published else { return }
        bundle.collections[index].isPublic = published
        commit(bundle, .collection(bundle.collections[index]))
    }

    /// Pins or unpins, deciding the end state now (see `toggleLike`).
    func togglePin(_ type: ProfilePin.TargetType, _ id: String) {
        let wanted = !isPinned(type, id)
        requireAuth { [self] in setPinned(type, id, wanted) }
    }

    func setPinned(_ type: ProfilePin.TargetType, _ id: String, _ pinned: Bool) {
        guard var bundle else { return }
        let index = bundle.pins.firstIndex { $0.targetType == type && $0.targetId == id }
        guard pinned != (index != nil) else { return }
        if let index {
            let pin = bundle.pins.remove(at: index)
            commit(bundle, .pin(targetType: type, targetId: id, position: pin.position, pinned: false))
        } else {
            let pin = ProfilePin(id: Identifiers.make(), profileId: bundle.profile.id, targetType: type, targetId: id, position: bundle.pins.count)
            bundle.pins.append(pin)
            commit(bundle, .pin(targetType: type, targetId: id, position: pin.position, pinned: true))
        }
    }

    func updateProfile(displayName: String? = nil, bio: String? = nil, profileSongId: String?? = nil, genreIds: [String]? = nil) {
        guard var bundle else { return }
        if let displayName { bundle.profile.displayName = String(displayName.prefix(80)) }
        if let bio { bundle.profile.bio = String(bio.prefix(600)) }
        if let profileSongId { bundle.profile.profileSongId = profileSongId }
        if let genreIds { bundle.profile.genreIds = Array(genreIds.prefix(40)) }
        let profile = bundle.profile
        // The server overwrites every field, so always send the complete profile.
        commit(bundle, .profile(displayName: profile.displayName, bio: profile.bio, avatarUrl: profile.avatarUrl, profileSongId: profile.profileSongId, genreIds: profile.genreIds))
    }

    /// Returns once every write made so far is saved in the durable queue (sent or not).
    func writesAreQueued() async {
        await writeChain?.value
    }

    /// Asks iOS for time to finish sending when the app leaves the foreground with
    /// writes in flight, so a Publish tapped on the way out still lands.
    func syncBeforeSuspending() {
        guard backgroundSync == .invalid else { return }
        backgroundSyncGeneration += 1
        let generation = backgroundSyncGeneration
        backgroundSync = UIApplication.shared.beginBackgroundTask(withName: "Resonote sync") { [weak self] in
            self?.endBackgroundSync(generation)
        }
        let outbox = outbox
        let chain = writeChain
        Task {
            await chain?.value
            await outbox.drain()
            endBackgroundSync(generation)
        }
    }

    /// Ends the background task `generation` began, and only that one.
    private func endBackgroundSync(_ generation: Int) {
        guard generation == backgroundSyncGeneration, backgroundSync != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSync)
        backgroundSync = .invalid
    }

    /// Back in the foreground after a real absence: writes waiting out a backoff go now.
    func didReturnToForeground() {
        enqueueOnChain { outbox in await outbox.retryNow() }
    }

    /// Sends what's waiting as soon as the network comes back.
    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.nmaass.resonote.network"))
    }

    private func networkChanged(satisfied: Bool) {
        let regained = satisfied && !networkAvailable
        networkAvailable = satisfied
        if regained { enqueueOnChain { outbox in await outbox.retryNow() } }
    }

    // MARK: Blocking and reporting

    /// Hides someone's writing everywhere in the app, at once and on every device.
    func block(_ profile: Profile) {
        guard isSignedIn, profile.id != self.profile?.id, !blockedIds.contains(profile.id) else { return }
        claimBlocks()
        blockedProfiles.append(profile)
        blockedIds.insert(profile.id)
        pendingBlocks[profile.id] = true
        persistBlocks()
        Task { await syncBlocks() }
    }

    func unblock(_ profileId: String) {
        guard blockedIds.contains(profileId) else { return }
        claimBlocks()
        blockedProfiles.removeAll { $0.id == profileId }
        blockedIds.remove(profileId)
        pendingBlocks[profileId] = false
        persistBlocks()
        Task { await syncBlocks() }
    }

    /// Sends block changes the server hasn't confirmed, then takes the server's list
    /// with those changes still on top. Only the person who made the changes sends them.
    private func syncBlocks() async {
        guard hasLiveSession, let owner = bundle?.profile.id else { return }
        if blocksOwner != owner { resetBlocks(for: owner) }
        let generation = sessionGeneration
        for (profileId, blocked) in pendingBlocks {
            do {
                if blocked { try await api.block(profileId: profileId) } else { try await api.unblock(profileId: profileId) }
                guard generation == sessionGeneration else { return }
                if pendingBlocks[profileId] == blocked { pendingBlocks[profileId] = nil }
            } catch let error as APIError where !error.isTransient && error != .unauthorized {
                // Refused for good (blocking yourself, say): stop asking, or it holds back the rest.
                guard generation == sessionGeneration else { return }
                if pendingBlocks[profileId] == blocked { pendingBlocks[profileId] = nil }
            } catch {
                break
            }
        }
        guard let server = try? await api.blockedProfiles(), generation == sessionGeneration else {
            persistBlocks()
            return
        }
        var profiles = server.filter { pendingBlocks[$0.id] != false }
        for profile in blockedProfiles where pendingBlocks[profile.id] == true && !profiles.contains(where: { $0.id == profile.id }) {
            profiles.append(profile)
        }
        if profiles != blockedProfiles {
            blockedProfiles = profiles
            blockedIds = Set(profiles.map(\.id))
        }
        persistBlocks()
    }

    private func persistBlocks() {
        let cache = BlockCache(owner: blocksOwner, profiles: blockedProfiles, pending: pendingBlocks)
        Task { await BlockCache.write(cache, to: Self.blocksFile) }
    }

    /// Block changes made now belong to the signed-in person; anyone else's are dropped first.
    private func claimBlocks() {
        guard let owner = bundle?.profile.id, blocksOwner != owner else { return }
        if blocksOwner != nil { resetBlocks(for: owner) } else { blocksOwner = owner }
    }

    /// Forgets the blocked list and unsent block changes on this device (sign-out, or
    /// another person signing in) and starts a list for `owner`.
    private func resetBlocks(for owner: String?) {
        blocksOwner = owner
        blockedProfiles = []
        blockedIds = []
        pendingBlocks = [:]
        persistBlocks()
    }

    // MARK: Internals

    private func commit(_ updated: ProfileBundle, _ operation: SyncOperation) {
        let previous = bundle
        bundle = updated
        rebuildDerived(from: previous)
        localRevision += 1
        localWrites.append((localRevision, operation.queueKey))
        if localWrites.count > Self.localWriteLimit { localWrites.removeFirst(localWrites.count - Self.localWriteLimit) }
        persistBundle()
        let owner = updated.profile.id
        enqueueOnChain { outbox in await outbox.enqueue(operation, owner: owner) }
    }

    /// Runs `work` against the outbox after everything queued before it.
    private func enqueueOnChain(_ work: @escaping @Sendable (SyncOutbox) async -> Void) {
        let previous = writeChain
        let outbox = outbox
        writeChain = Task {
            await previous?.value
            await work(outbox)
        }
    }

    private func localKeys(since revision: Int) -> Set<String> {
        Set(localWrites.filter { $0.revision > revision }.map(\.key))
    }

    private func apply(serverBundle fresh: ProfileBundle, unconfirmed: Set<String>) {
        var merged = fresh
        if let local = bundle, local.profile.id == fresh.profile.id, !unconfirmed.isEmpty {
            merged.likes = Self.merge(server: fresh.likes, local: local.likes, unconfirmed: unconfirmed) { "like:\($0.entityId)" }
            merged.entries = Self.merge(server: fresh.entries, local: local.entries, unconfirmed: unconfirmed) { "entry:\($0.id)" }
            merged.listens = Self.merge(server: fresh.listens, local: local.listens, unconfirmed: unconfirmed) { "listen:\($0.id)" }
            merged.collections = Self.merge(server: fresh.collections, local: local.collections, unconfirmed: unconfirmed) { "collection:\($0.id)" }
            merged.pins = Self.merge(server: fresh.pins, local: local.pins, unconfirmed: unconfirmed) { "pin:\($0.targetType.rawValue):\($0.targetId)" }
            merged.genreAssertions = Self.merge(server: fresh.genreAssertions, local: local.genreAssertions, unconfirmed: unconfirmed) { "genre:\($0.entityId):\($0.genreId)" }
            if unconfirmed.contains("profile") { merged.profile = local.profile }
        }
        serverEntryIds = Set(fresh.entries.map(\.id))
        absorb(fresh.catalog)
        guard merged != bundle else { return }
        let previous = bundle
        bundle = merged
        rebuildDerived(from: previous)
        persistBundle()
    }

    /// Server rows, except that any object with an unconfirmed local write keeps its local state
    /// (including being absent, for deletions).
    private static func merge<T>(server: [T], local: [T], unconfirmed: Set<String>, key: (T) -> String) -> [T] {
        let kept = server.filter { !unconfirmed.contains(key($0)) }
        let pending = local.filter { unconfirmed.contains(key($0)) }
        return pending + kept
    }

    /// Recomputes the lookups that changed between `previous` and `bundle`, assigning
    /// only what differs so unrelated readers are not invalidated.
    private func rebuildDerived(from previous: ProfileBundle?) {
        let current = bundle
        if current?.profile.id != ownerId { ownerId = current?.profile.id }
        if previous?.likes != current?.likes {
            let liked = Set(current?.likes.map(\.entityId) ?? [])
            if liked != likedIds { likedIds = liked }
        }
        if previous?.pins != current?.pins {
            let pins = Set(current?.pins.map { Self.pinKey($0.targetType, $0.targetId) } ?? [])
            if pins != pinKeys { pinKeys = pins }
        }
        if previous?.genreAssertions != current?.genreAssertions {
            let assertions = Set(current?.genreAssertions.map { Self.assertionKey($0.entityId, $0.genreId) } ?? [])
            if assertions != assertionKeys { assertionKeys = assertions }
        }
        let entriesChanged = previous?.entries != current?.entries
        if entriesChanged {
            let entries = current?.entries ?? []
            entriesById = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            entriesByEntity = Dictionary(grouping: entries, by: \.entityId).mapValues { list in
                list.sorted { $0.updatedAt > $1.updatedAt }
            }
            recentlyNotedSongIds = Array(entries
                .filter { $0.entityKind == .song }
                .sorted { $0.updatedAt > $1.updatedAt }
                .map(\.entityId)
                .prefix(30))
        }
        if entriesChanged || previous?.listens != current?.listens {
            let fresh = Self.habits(entries: current?.entries ?? [], listens: current?.listens ?? [])
            if fresh != habits { habits = fresh }
        }
    }

    private static func pinKey(_ type: ProfilePin.TargetType, _ id: String) -> String { "\(type.rawValue):\(id)" }
    private static func assertionKey(_ entityId: String, _ genreId: String) -> String { "\(entityId)|\(genreId)" }

    private static func habits(entries: [JournalEntry], listens: [ListenLog]) -> TagSuggestions {
        let lensCounts = Dictionary(entries.flatMap(\.lenses).map { ($0, 1) }, uniquingKeysWith: +)
        let moodCounts = Dictionary(listens.flatMap(\.moods).map { ($0, 1) }, uniquingKeysWith: +)
        let lenses = MusicLens.allCases.enumerated().sorted { a, b in
            let (left, right) = (lensCounts[a.element] ?? 0, lensCounts[b.element] ?? 0)
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element)
        let rankedMoods = moodCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        var seen = Set<String>()
        let moods = (rankedMoods + Vocabulary.moods).filter { seen.insert($0).inserted }
        return TagSuggestions(lenses: Array(lenses.prefix(4)), moods: Array(moods.prefix(4)))
    }

    private func persistBundle() {
        scheduleSave(.bundle)
        publishWidgetFacts()
    }

    private func persistCatalog() {
        scheduleSave(.catalog)
    }

    /// Tells the widget what changed about the person, only when something it shows did.
    private func publishWidgetFacts() {
        let facts = WidgetFacts(bundle: bundle, habits: habits, recentlyNotedSongIds: recentlyNotedSongIds)
        guard facts != widgetFacts else { return }
        widgetFacts = facts
        WidgetBridge.personDidChange(signedIn: facts.signedIn, handle: facts.handle, habits: facts.habits, recentlyNotedSongIds: facts.recentlyNotedSongIds)
    }

    /// Coalesces bursts of changes (a page load, a search import) into one write,
    /// encoded and written off the main actor. Writes run in order, one at a time.
    private func scheduleSave(_ file: SessionFiles.File) {
        let wasIdle = pendingSaves.isEmpty
        pendingSaves.insert(file)
        guard wasIdle else { return }
        let previous = saveChain
        saveChain = Task {
            await previous?.value
            try? await Task.sleep(for: .milliseconds(250))
            let files = pendingSaves
            pendingSaves = []
            let bundle: SessionFiles.BundleWrite = files.contains(.bundle) ? (self.bundle.map { .write($0) } ?? .remove) : .unchanged
            let catalog: SessionFiles.CatalogWrite? = files.contains(.catalog)
                ? SessionFiles.CatalogWrite(index: catalog, keeping: Self.catalogIds(referencedBy: self.bundle), limit: Self.catalogCacheLimit)
                : nil
            await SessionFiles.write(bundle: bundle, to: Self.bundleFile, catalog: catalog, to: Self.catalogFile)
        }
    }

    /// Every catalog row the person's own journal points at, which the cache always keeps.
    private static func catalogIds(referencedBy bundle: ProfileBundle?) -> Set<String> {
        guard let bundle else { return [] }
        var ids = Set<String>()
        ids.formUnion(bundle.likes.map(\.entityId))
        for entry in bundle.entries {
            ids.insert(entry.entityId)
            ids.formUnion(entry.references.map(\.entityId))
        }
        ids.formUnion(bundle.listens.map(\.songId))
        for collection in bundle.collections { ids.formUnion(collection.items.map(\.entityId)) }
        ids.formUnion(bundle.pins.filter { $0.targetType == .entity }.map(\.targetId))
        ids.formUnion(bundle.genreAssertions.map(\.entityId))
        if let song = bundle.profile.profileSongId { ids.insert(song) }
        return ids
    }

    // MARK: Failed writes

    /// Keeps `serverEntryIds` current as the server confirms entries, so a later refusal
    /// of an edit is treated as an edit even before the next refresh.
    private func watchConfirmations() async {
        for await confirmation in await outbox.confirmations() {
            guard confirmation.key.hasPrefix("entry:") else { continue }
            let id = String(confirmation.key.dropFirst("entry:".count))
            if confirmation.op == "delete-entry" {
                serverEntryIds.remove(id)
            } else {
                serverEntryIds.insert(id)
            }
        }
    }

    private func watchSyncFailures() async {
        for await failure in await outbox.failures() {
            switch failure.kind {
            case .willRetry:
                syncNotice = "Saved on this device. \(failure.message)"
            case .needsSignIn:
                markSessionExpired()
            case .rejected(let status):
                handleRejected(failure, status: status)
            }
        }
    }

    /// The server will never take this write. Give back what it carried and undo it on
    /// this device, and say so plainly.
    private func handleRejected(_ failure: SyncOutbox.Failure, status: Int?) {
        if failure.op == "collection", status == 409, retryWithNewSlug(key: failure.key) { return }
        let owner = failure.owner ?? ownerId
        if failure.op == "entry", let body = failure.body,
           let payload = try? JSONDecoder().decode(EntryPayload.self, from: body) {
            restoreAsDraft(payload.entry, owner: owner)
            syncNotice = "Resonote couldn't publish this. It's back in your drafts."
        } else if failure.op == "listen", keepWords(op: failure.op, body: failure.body, owner: owner, publishedEntryIds: []) {
            syncNotice = "Resonote couldn't save that listen. Its note is in your drafts."
        } else {
            syncNotice = "Couldn't save that change. \(failure.message)"
        }
        // Without an unconfirmed write, the server's copy of this object replaces the local one.
        Task { await refreshSession() }
    }

    /// Gives back the words carried by writes that left the queue without reaching the
    /// server: each goes to its writer's drafts, out of sight of anyone else on this device.
    private func keepWords(from writes: [SyncOutbox.PendingWrite], publishedEntryIds: Set<String>, fallbackOwner: String?) {
        for write in writes {
            keepWords(op: write.op, body: write.body, owner: write.owner ?? fallbackOwner, publishedEntryIds: publishedEntryIds, mayHaveLanded: write.mayHaveReachedServer)
        }
    }

    /// An entry's words go to its draft (its edit draft when it was already published, or
    /// may have landed after all); a listen's note goes to its song's draft, kept private.
    /// Returns whether there were words.
    @discardableResult
    private func keepWords(op: String?, body: Data?, owner: String?, publishedEntryIds: Set<String>, mayHaveLanded: Bool = false) -> Bool {
        guard let body else { return false }
        let store = DraftStore.shared.scoped(to: owner)
        let decoder = JSONDecoder()
        switch op {
        case "entry":
            guard let entry = (try? decoder.decode(EntryPayload.self, from: body))?.entry, !entry.document.isBlank else { return false }
            // Unsure whether the server has it: an edit draft is safe either way, since
            // publishing it saves under the same id instead of adding a second entry.
            let isEdit = mayHaveLanded || publishedEntryIds.contains(entry.id) || entry.createdAt != entry.updatedAt
            Self.restore(entry, asEdit: isEdit, in: store)
            return true
        case "listen":
            guard let listen = (try? decoder.decode(ListenPayload.self, from: body))?.listen,
                  let note = listen.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return false }
            let document = RichDocument.plain(note)
            let words = JournalEntry(id: listen.id, profileId: "", entityId: listen.songId, entityKind: .song, document: document, plainText: document.plainText, isPublic: false, createdAt: listen.listenedAt, updatedAt: listen.listenedAt)
            Self.restore(words, asEdit: false, in: store)
            return true
        default:
            return false
        }
    }

    /// A collection name the server already has (made on the web, say): try the next free slug.
    private func retryWithNewSlug(key: String) -> Bool {
        let id = String(key.dropFirst("collection:".count))
        guard var bundle, let index = bundle.collections.firstIndex(where: { $0.id == id }) else { return false }
        var tried = reslugTried[id] ?? []
        guard tried.count < 3 else { return false }
        var collection = bundle.collections[index]
        tried.insert(collection.slug)
        reslugTried[id] = tried
        collection.slug = Slug.unique(collection.name, taken: tried.union(bundle.collections.map(\.slug)))
        bundle.collections[index] = collection
        commit(bundle, .collection(collection))
        return true
    }

    /// Puts a refused entry's words back where the composer will find them, never over a draft.
    /// An entry the server never had also leaves this device's journal.
    private func restoreAsDraft(_ entry: JournalEntry, owner: String?) {
        let isEdit = serverEntryIds.contains(entry.id)
        Self.restore(entry, asEdit: isEdit, in: DraftStore.shared.scoped(to: owner))
        if !isEdit, var bundle, bundle.profile.id == owner {
            let previous = bundle
            bundle.entries.removeAll { $0.id == entry.id }
            self.bundle = bundle
            rebuildDerived(from: previous)
            persistBundle()
        }
    }

    /// Adds `entry`'s words to its draft in `store`: the edit draft for a published entry,
    /// else the new-entry draft for its subject. Never replaces what a draft holds, and
    /// never makes a private draft public.
    private static func restore(_ entry: JournalEntry, asEdit isEdit: Bool, in store: DraftStore) {
        let key = Draft.key(kind: entry.entityKind, entityId: entry.entityId, entryId: isEdit ? entry.id : nil)
        var draft = store.load(key: key) ?? Draft(entityId: entry.entityId, entityKind: entry.entityKind, entryId: isEdit ? entry.id : nil, document: RichDocument(content: []), isPublic: entry.isPublic)
        let kept = draft.document.isBlank ? [] : draft.document.content
        if !draft.document.plainText.contains(entry.plainText) {
            draft.document = RichDocument(content: kept + entry.document.content)
        }
        if draft.title.isEmpty { draft.title = entry.title ?? "" }
        if draft.worked.isEmpty { draft.worked = entry.worked ?? "" }
        if draft.didntWork.isEmpty { draft.didntWork = entry.didntWork ?? "" }
        draft.lenses += entry.lenses.filter { !draft.lenses.contains($0) }
        draft.isPublic = draft.isPublic && entry.isPublic
        draft.updatedAt = Date()
        store.save(draft)
    }
}

/// The `entry` op's payload, to give a refused entry back.
private nonisolated struct EntryPayload: Decodable {
    var entry: JournalEntry
}

/// The `listen` op's payload, to give a refused listen's note back.
private nonisolated struct ListenPayload: Decodable {
    var listen: ListenLog
}

/// What the widget shows about the person.
private struct WidgetFacts: Equatable {
    var signedIn: Bool
    var handle: String?
    var habits: TagSuggestions?
    var recentlyNotedSongIds: [String]

    init(bundle: ProfileBundle?, habits: TagSuggestions, recentlyNotedSongIds: [String]) {
        signedIn = bundle != nil
        handle = bundle?.profile.handle
        self.habits = bundle == nil ? nil : habits
        self.recentlyNotedSongIds = bundle == nil ? [] : recentlyNotedSongIds
    }
}

/// The blocked list as last known, plus changes the server hasn't confirmed, for one person.
nonisolated struct BlockCache: Codable, Sendable {
    /// The profile the list belongs to (nil in caches written before it was recorded).
    var owner: String?
    var profiles: [Profile]
    var pending: [String: Bool]

    @concurrent
    static func write(_ cache: BlockCache, to name: String) async {
        if cache.profiles.isEmpty, cache.pending.isEmpty {
            SharedFile.remove(name)
        } else {
            SharedFile.write(cache, to: name)
        }
    }
}

/// Writes the session's cache files away from the main actor.
nonisolated enum SessionFiles {
    enum File: Hashable { case bundle, catalog }

    enum BundleWrite: Sendable {
        case unchanged
        case write(ProfileBundle)
        case remove
    }

    /// The catalog to cache, bounded on the way to disk.
    struct CatalogWrite: Sendable {
        var index: CatalogIndex
        var keeping: Set<String>
        var limit: Int
    }

    @concurrent
    static func write(bundle: BundleWrite, to bundleFile: String, catalog: CatalogWrite?, to catalogFile: String) async {
        switch bundle {
        case .unchanged: break
        case .write(let value): SharedFile.write(value, to: bundleFile)
        case .remove: SharedFile.remove(bundleFile)
        }
        if let catalog { SharedFile.write(catalog.index.pruned(keeping: catalog.keeping, limit: catalog.limit), to: catalogFile) }
    }
}
