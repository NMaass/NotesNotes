import ResonoteKit
import Synchronization

/// The app's bearer token: read from the keychain once, then served from memory, so
/// every request doesn't cost a keychain round trip. Sign-in and sign-out update both.
/// App only: the extensions read the keychain themselves, since the app can change
/// the token while they keep running.
nonisolated final class SessionToken: Sendable {
    /// `.some(nil)` once the keychain was read and had nothing.
    private let cached = Mutex<String??>(nil)
    private let store: TokenStore

    init(store: TokenStore = .shared) {
        self.store = store
    }

    func read() -> String? {
        cached.withLock { value in
            if let known = value { return known }
            let read = store.read()
            // An empty read may only mean the keychain is locked (before first unlock): ask again next time.
            if read != nil { value = .some(read) }
            return read
        }
    }

    func save(_ token: String) {
        store.save(token)
        cached.withLock { $0 = .some(token) }
    }

    func delete() {
        store.delete()
        cached.withLock { $0 = .some(nil) }
    }
}
