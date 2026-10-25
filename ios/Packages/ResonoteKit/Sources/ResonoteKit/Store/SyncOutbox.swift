import Foundation

/// A durable, per-object write queue for `POST /api/sync`.
///
/// The web app's contract is "later intent cannot be reversed by an earlier slow
/// response." The outbox keeps that contract across launches:
/// - writes to the same object share a key (`SyncOperation.queueKey`) and never run concurrently;
/// - a newer write replaces an older write for the same key that is not being sent, so only the latest intent goes out;
/// - every write stays on disk until the server confirms or refuses it, including while it
///   is being sent, so a write survives the app being killed mid-request (every op is safe to resend);
/// - a write that fails waits out its own backoff while writes to other objects keep flowing;
/// - a write leaves the queue only when the server confirms it or refuses it for good (a
///   4xx). Network trouble, throttling, and server errors (5xx, a missing database, a reply
///   that can't be read) are retried with capped backoff for as long as it takes;
/// - each write belongs to the person who made it and is only ever sent with their session.
///   An expired session pauses the queue without dropping anything; only an explicit
///   sign-out, or a different person signing in, clears it, and both hand back what they
///   removed so the app can keep the words it carried.
public actor SyncOutbox {
    public struct PendingWrite: Codable, Sendable, Hashable {
        public var id: UUID
        public var key: String
        /// The op name (`entry`, `delete-entry`, …), for outcomes that depend on it.
        public var op: String?
        public var body: Data
        public var attempts: Int
        public var enqueuedAt: Date
        /// The profile that made the write. It is only sent while that profile is signed in.
        public var owner: String?
        /// Not sent again before this time (backoff after a failure).
        public var notBefore: Date?
        /// Set on writes handed back by `adopt` or `clear` that were sent at least once (or
        /// were out when the queue let go of them): the server may hold them even so.
        /// Not saved.
        public var mayHaveReachedServer = false

        init(key: String, op: String?, body: Data, owner: String?) {
            id = UUID()
            self.key = key
            self.op = op
            self.body = body
            attempts = 0
            enqueuedAt = Date()
            self.owner = owner
            notBefore = nil
        }

        private enum CodingKeys: String, CodingKey { case id, key, op, body, attempts, enqueuedAt, owner, notBefore }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            key = try c.decode(String.self, forKey: .key)
            op = try c.decodeIfPresent(String.self, forKey: .op)
            body = try c.decode(Data.self, forKey: .body)
            attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
            enqueuedAt = try c.decodeIfPresent(Date.self, forKey: .enqueuedAt) ?? Date()
            owner = try c.decodeIfPresent(String.self, forKey: .owner)
            notBefore = try c.decodeIfPresent(Date.self, forKey: .notBefore)
        }
    }

    public struct Failure: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            /// Still queued on this device; it will be sent again.
            case willRetry
            /// The session ended; queued writes wait for the same person to sign in again.
            case needsSignIn
            /// The server refused the write for good (a 4xx); it left the queue.
            case rejected(status: Int?)
        }

        public var key: String
        public var op: String?
        public var message: String
        public var kind: Kind
        /// The write's payload, so the app can give back what a refused write carried.
        public var body: Data?
        /// The profile that made the write, so what it carried goes back to that person.
        public var owner: String?
    }

    /// A write the server confirmed.
    public struct Confirmation: Sendable, Hashable {
        public var key: String
        public var op: String?
    }

    /// A point in the outbox's history, taken just before reading server state.
    public struct Checkpoint: Sendable, Hashable {
        fileprivate var revision: Int
        fileprivate var unconfirmed: Set<String>
    }

    /// What the queue file holds.
    private struct Saved: Codable {
        var owner: String?
        var writes: [PendingWrite]
    }

    private static let recentWriteLimit = 500

    private let client: APIClient
    private let fileURL: URL
    private var loaded = false
    private var writes: [PendingWrite] = []
    private var owner: String?
    /// The write being sent for each key, by id. Memory only: after a relaunch every saved write is pending.
    private var inFlight: [String: UUID] = [:]
    /// Bumped by `clear()`, so a write that was in flight then is never put back.
    private var epoch = 0
    private var pausedForAuth = false
    private var drainTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var reportedRetry = false
    private var reportedPause = false
    private var failureContinuations: [UUID: AsyncStream<Failure>.Continuation] = [:]
    private var confirmationContinuations: [UUID: AsyncStream<Confirmation>.Continuation] = [:]
    private var sendOverride: (@Sendable (Data) async throws -> Void)?
    /// Counts enqueued writes; with `recentWrites`, tells which objects changed after a checkpoint.
    private var revision = 0
    private var recentWrites: [(revision: Int, key: String)] = []

    /// The queue file is read on first use, off the caller's actor.
    public init(client: APIClient, fileURL: URL = AppGroup.fileURL("outbox.json")) {
        self.client = client
        self.fileURL = fileURL
    }

    /// For tests: replaces the network send.
    public func setSendOverride(_ send: (@Sendable (Data) async throws -> Void)?) {
        sendOverride = send
    }

    // MARK: State

    /// Writes not yet confirmed by the server, in flight included.
    public var pendingCount: Int {
        loadIfNeeded()
        return writes.count
    }

    /// Keys with a write that has not been confirmed by the server yet.
    public var unconfirmedKeys: Set<String> {
        loadIfNeeded()
        return Set(writes.map(\.key))
    }

    /// Whether the queue is waiting for its owner to sign in again.
    public var isPausedForSignIn: Bool { pausedForAuth }

    /// The profile whose writes the queue holds.
    public var currentOwner: String? {
        loadIfNeeded()
        return owner
    }

    /// How many writes `adopt(owner: profileId)` would remove: everything someone else made.
    public func pendingCount(notOwnedBy profileId: String, keepingUnowned: Bool = false) -> Int {
        loadIfNeeded()
        return writes.filter { Self.belongsElsewhere($0, from: profileId, keepingUnowned: keepingUnowned) }.count
    }

    /// Marks the moment before a server read, so `keysToKeepLocal(since:)` can tell
    /// which objects that read may not reflect.
    public func checkpoint() -> Checkpoint {
        loadIfNeeded()
        return Checkpoint(revision: revision, unconfirmed: unconfirmedKeys)
    }

    /// Objects whose local state must win over server data read after `checkpoint`:
    /// anything unconfirmed then or now, and anything written since. A write the server
    /// confirmed while the read was in flight may be missing from that read.
    public func keysToKeepLocal(since checkpoint: Checkpoint) -> Set<String> {
        var keys = checkpoint.unconfirmed.union(unconfirmedKeys)
        for write in recentWrites where write.revision > checkpoint.revision {
            keys.insert(write.key)
        }
        return keys
    }

    // MARK: Writing

    /// Queues `operation` for `owner` and saves the queue before returning, so a caller
    /// that awaits this can safely let go of its own copy (a draft, say).
    public func enqueue(_ operation: SyncOperation, owner: String? = nil) {
        loadIfNeeded()
        guard let body = try? JSONEncoder().encode(operation) else { return }
        let key = operation.queueKey
        revision += 1
        recentWrites.append((revision, key))
        if recentWrites.count > Self.recentWriteLimit { recentWrites.removeFirst(recentWrites.count - Self.recentWriteLimit) }
        // The newer intent says everything; an older write still waiting has nothing left to add.
        let sending = inFlight[key]
        writes.removeAll { $0.key == key && $0.id != sending }
        let writer = owner ?? self.owner
        writes.append(PendingWrite(key: key, op: operation.opName, body: body, owner: writer))
        if self.owner == nil { self.owner = writer }
        // A pin still waiting (or out) for something being deleted must not land after the
        // delete and bring back a pin on nothing: queue the unpin, the newest intent for it.
        if let pin = operation.unpinOnDelete, writes.contains(where: { $0.key == pin.queueKey }) {
            enqueue(pin, owner: writer)
            return
        }
        persist()
        startDrain()
    }

    /// A session for `profileId` is confirmed (sign-in, or a refresh). Writes another
    /// person left behind are dropped; this person's writes are sent.
    /// - Parameter keepingUnowned: treat writes saved before owners were recorded as this
    ///   person's. Pass it only when this device's cached session already says it's them.
    /// - Returns: the writes dropped, so the app can keep the words they carried for the
    ///   person who wrote them.
    @discardableResult
    public func adopt(owner profileId: String, keepingUnowned: Bool = false) -> [PendingWrite] {
        loadIfNeeded()
        let dropped = writes.filter { Self.belongsElsewhere($0, from: profileId, keepingUnowned: keepingUnowned) }.map(handedBack)
        writes.removeAll { Self.belongsElsewhere($0, from: profileId, keepingUnowned: keepingUnowned) }
        if !dropped.isEmpty { epoch += 1 }
        for index in writes.indices where writes[index].owner == nil {
            writes[index].owner = profileId
        }
        owner = profileId
        pausedForAuth = false
        reportedPause = false
        persist()
        startDrain()
        return dropped
    }

    private func handedBack(_ write: PendingWrite) -> PendingWrite {
        var copy = write
        copy.mayHaveReachedServer = write.attempts > 0 || inFlight[write.key] == write.id
        return copy
    }

    private static func belongsElsewhere(_ write: PendingWrite, from profileId: String, keepingUnowned: Bool) -> Bool {
        guard let owner = write.owner else { return !keepingUnowned }
        return owner != profileId
    }

    /// The session expired: keep every write and wait for the same person to sign in.
    public func pauseForSignIn() {
        loadIfNeeded()
        pausedForAuth = true
        wakeTask?.cancel()
        wakeTask = nil
    }

    /// Sends every waiting write now, without waiting out its backoff: the app came back
    /// to the foreground, the network returned, or the server just answered. Failures back
    /// off again from where they were. Does not lift a pause for sign-in.
    public func retryNow() {
        loadIfNeeded()
        var changed = false
        for index in writes.indices where writes[index].notBefore != nil && (writes[index].owner == nil || writes[index].owner == owner) {
            writes[index].notBefore = nil
            changed = true
        }
        if changed { persist() }
        startDrain()
    }

    /// Forgets everything queued (an explicit, confirmed sign-out). A write in flight
    /// right now finishes, but is never put back or sent again.
    /// - Returns: the writes removed, so the app can keep the words they carried.
    @discardableResult
    public func clear() -> [PendingWrite] {
        loadIfNeeded()
        let removed = writes.map(handedBack)
        epoch += 1
        writes.removeAll()
        owner = nil
        pausedForAuth = false
        reportedPause = false
        reportedRetry = false
        wakeTask?.cancel()
        wakeTask = nil
        persist()
        return removed
    }

    public func failures() -> AsyncStream<Failure> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Failure>.makeStream()
        failureContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    /// Every write the server confirms, as it happens.
    public func confirmations() -> AsyncStream<Confirmation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Confirmation>.makeStream()
        confirmationContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConfirmationContinuation(id) }
        }
        return stream
    }

    // MARK: Sending

    /// Sends everything that can be sent now and returns once nothing more is due
    /// (writes waiting out a backoff are left for their own time). Safe to call repeatedly.
    public func drain() async {
        loadIfNeeded()
        startDrain()
        await drainTask?.value
    }

    private func startDrain() {
        guard drainTask == nil, !pausedForAuth else { return }
        drainTask = Task { await self.runDrain() }
    }

    private func runDrain() async {
        defer {
            drainTask = nil
            scheduleWake()
        }
        while !pausedForAuth, let write = nextDue(at: Date()) {
            let started = epoch
            inFlight[write.key] = write.id
            let outcome = await send(write)
            if inFlight[write.key] == write.id { inFlight[write.key] = nil }
            // Cleared (sign-out) or handed to another person while it was out: never put it back.
            guard started == epoch else { continue }
            settle(write, outcome)
        }
    }

    /// The oldest write that may go now: its object has nothing in flight, its backoff
    /// has passed, and it belongs to the person signed in.
    private func nextDue(at now: Date) -> PendingWrite? {
        writes.first { write in
            inFlight[write.key] == nil
                && (write.notBefore ?? .distantPast) <= now
                && (write.owner == nil || write.owner == owner)
        }
    }

    private func settle(_ write: PendingWrite, _ outcome: Outcome) {
        guard let index = writes.firstIndex(where: { $0.id == write.id }) else { return }
        switch outcome {
        case .sent:
            writes.remove(at: index)
            reportedRetry = false
            confirm(Confirmation(key: write.key, op: write.op))
        case .retry(let message):
            if writes.contains(where: { $0.key == write.key && $0.id != write.id }) {
                // A newer write for the same object is queued and carries the whole intent.
                writes.remove(at: index)
                break
            }
            // Never given up: the write stays until the server takes it or refuses it for good.
            var retry = writes[index]
            retry.attempts += 1
            retry.notBefore = Date().addingTimeInterval(Self.backoff(afterAttempts: retry.attempts))
            writes[index] = retry
            if retry.attempts >= 2, !reportedRetry {
                reportedRetry = true
                report(Failure(key: write.key, op: write.op, message: message, kind: .willRetry, body: nil, owner: write.owner))
            }
        case .unauthorized:
            pausedForAuth = true
            if !reportedPause {
                reportedPause = true
                report(Failure(key: write.key, op: write.op, message: APIError.unauthorized.localizedDescription, kind: .needsSignIn, body: nil, owner: write.owner))
            }
        case .rejected(let message, let status):
            writes.remove(at: index)
            report(Failure(key: write.key, op: write.op, message: message, kind: .rejected(status: status), body: write.body, owner: write.owner))
        }
        persist()
    }

    /// One wake-up for the earliest write still waiting out its backoff.
    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        guard !pausedForAuth else { return }
        let waiting = writes.filter { inFlight[$0.key] == nil && ($0.owner == nil || $0.owner == owner) }.compactMap(\.notBefore)
        guard let earliest = waiting.min() else { return }
        let delay = max(0.05, earliest.timeIntervalSinceNow)
        wakeTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.startDrain()
        }
    }

    /// 2, 4, 8 … seconds, at most five minutes.
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        min(300, pow(2, Double(min(attempts, 9))))
    }

    enum Outcome: Equatable {
        case sent
        case retry(String)
        case unauthorized
        case rejected(String, status: Int?)
    }

    private func send(_ write: PendingWrite) async -> Outcome {
        do {
            if let sendOverride {
                try await sendOverride(write.body)
            } else {
                try await client.syncRaw(write.body)
            }
            return .sent
        } catch let error as APIError {
            return Self.outcome(of: error, op: write.op)
        } catch is CancellationError {
            return .retry("Cancelled")
        } catch {
            return .retry(error.localizedDescription)
        }
    }

    /// Only a definitive answer takes a write out of the queue. The server's contract
    /// (docs/IOS_API.md) is that a write it will never accept answers 4xx; everything
    /// else (no network, a timeout, throttling, a 5xx or an HTML error page from the edge,
    /// a missing database, a reply this version can't read) says nothing about the write,
    /// so it waits and goes again.
    static func outcome(of error: APIError, op: String?) -> Outcome {
        switch error {
        case .unauthorized:
            return .unauthorized
        case .server(let status, let message):
            // Deleting something that isn't in this person's journal leaves it not there: done.
            if status == 404, op == "delete-entry" || op == "delete-collection" { return .sent }
            return error.isTransient ? .retry(message) : .rejected(message, status: status)
        case .transport, .notConfigured, .decoding:
            return .retry(error.localizedDescription)
        }
    }

    private func report(_ failure: Failure) {
        for continuation in failureContinuations.values { continuation.yield(failure) }
    }

    private func confirm(_ confirmation: Confirmation) {
        for continuation in confirmationContinuations.values { continuation.yield(confirmation) }
    }

    private func removeContinuation(_ id: UUID) {
        failureContinuations[id] = nil
    }

    private func removeConfirmationContinuation(_ id: UUID) {
        confirmationContinuations[id] = nil
    }

    // MARK: Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let saved = try? decoder.decode(Saved.self, from: data) {
            owner = saved.owner
            writes = saved.writes
        } else if let legacy = try? decoder.decode([PendingWrite].self, from: data) {
            writes = legacy
        }
        // A new launch tries again at once; the attempt count keeps its place.
        for index in writes.indices { writes[index].notBefore = nil }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Saved(owner: owner, writes: writes)) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
