import Foundation

/// An unpublished entry. Drafts never leave the device until published, and
/// background data never replaces one (a stable-interface contract).
public struct Draft: Codable, Sendable, Hashable {
    public var entityId: String
    public var entityKind: EntityKind
    /// Set when editing an already-published entry.
    public var entryId: String?
    /// Set while the song the words are about isn't matched to the catalog yet
    /// (`entityId` is empty then). The words move to the song's draft once it is.
    public var track: NowPlayingTrack?
    public var title: String
    public var document: RichDocument
    public var lenses: [MusicLens]
    public var worked: String
    public var didntWork: String
    public var isPublic: Bool
    public var updatedAt: Date

    public init(entityId: String, entityKind: EntityKind, entryId: String? = nil, track: NowPlayingTrack? = nil, title: String = "", document: RichDocument = .empty, lenses: [MusicLens] = [], worked: String = "", didntWork: String = "", isPublic: Bool = true, updatedAt: Date = Date()) {
        self.entityId = entityId
        self.entityKind = entityKind
        self.entryId = entryId
        self.track = track
        self.title = title
        self.document = document
        self.lenses = lenses
        self.worked = worked
        self.didntWork = didntWork
        self.isPublic = isPublic
        self.updatedAt = updatedAt
    }

    /// One draft per entity for new entries, one per entry when editing, and one per
    /// unmatched track.
    public var key: String {
        if entityId.isEmpty, entryId == nil, let track { return Self.key(for: track) }
        return Self.key(kind: entityKind, entityId: entityId, entryId: entryId)
    }

    /// Whether the draft is about a track that isn't matched to a catalog song yet.
    public var isUnmatched: Bool { entityId.isEmpty && track != nil }

    public static func key(kind: EntityKind, entityId: String, entryId: String?) -> String {
        if let entryId { return "entry-\(entryId)" }
        return "\(kind.rawValue)-\(entityId)"
    }

    /// The key for words about a track that isn't matched yet.
    public static func key(for track: NowPlayingTrack) -> String {
        let safe = track.identity.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return "track-" + String(String(safe).prefix(120))
    }
}

/// Drafts as small JSON files in the shared container.
///
/// Drafts belong to the person who wrote them. A store scoped to a profile
/// (`scoped(to:)`) keeps that person's drafts in their own folder
/// (`drafts/owner-<id>/<key>.json`), so the next person to sign in on this iPhone never
/// sees, opens, or publishes them, and two people's drafts about the same song never
/// share a file. Drafts written while nobody was signed in (`drafts/<key>.json`) are
/// unowned: whoever signs in next sees them, and saving one moves it into their folder.
public struct DraftStore: Sendable {
    /// Unowned drafts. Scope it to the signed-in profile before reading or writing theirs.
    public static let shared = DraftStore()

    /// The profile whose drafts this store reads and writes; nil for unowned drafts.
    public let owner: String?
    private let root: URL

    public init(directory: URL = AppGroup.containerURL.appending(path: "drafts", directoryHint: .isDirectory), owner: String? = nil) {
        root = directory
        self.owner = owner.flatMap { $0.isEmpty ? nil : $0 }
        // A person's own folder is made by their first save.
        if self.owner == nil { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    }

    /// The same drafts folder, read and written as `owner`'s.
    public func scoped(to owner: String?) -> DraftStore {
        DraftStore(directory: root, owner: owner)
    }

    private var directory: URL {
        guard let owner else { return root }
        let safe = String(owner.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }.prefix(80))
        return root.appending(path: "owner-\(safe)", directoryHint: .isDirectory)
    }

    /// This person's draft for `key`, else an unowned one.
    public func load(key: String) -> Draft? {
        for url in urls(for: key) {
            if let data = try? Data(contentsOf: url), let draft = try? JSONDecoder().decode(Draft.self, from: data) {
                return draft
            }
        }
        return nil
    }

    /// Saves into this person's folder. An unowned draft with the same key is now theirs,
    /// so its old copy goes.
    public func save(_ draft: Draft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        let target = url(for: draft.key, in: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if owner != nil { try? FileManager.default.removeItem(at: url(for: draft.key, in: root)) }
    }

    /// Keeps quick words (capture sheet, share sheet) as the draft for a new entry about
    /// an entity. An existing draft is never replaced: the words are added after it, and
    /// its visibility stays as the person set it.
    public func append(_ text: String, lenses: [MusicLens], isPublic: Bool, kind: EntityKind, entityId: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let key = Draft.key(kind: kind, entityId: entityId, entryId: nil)
        save(Self.adding(words, lenses: lenses, to: load(key: key)) {
            Draft(entityId: entityId, entityKind: kind, lenses: lenses, isPublic: isPublic)
        })
    }

    /// Keeps words about a track Resonote couldn't match yet, so they can follow the
    /// song once it is. Adds to words already kept for the same track.
    public func appendUnmatched(_ text: String, lenses: [MusicLens], isPublic: Bool, track: NowPlayingTrack) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        save(Self.adding(words, lenses: lenses, to: load(key: Draft.key(for: track))) {
            Draft(entityId: "", entityKind: .song, track: track, lenses: lenses, isPublic: isPublic)
        })
    }

    /// Words kept for `track` while it was unmatched.
    public func unmatched(for track: NowPlayingTrack) -> Draft? {
        load(key: Draft.key(for: track))
    }

    /// Moves words kept for an unmatched `track` onto the draft for `songId`, adding them
    /// after anything already there. Never replaces a draft; a private choice stays private.
    @discardableResult
    public func attachUnmatched(_ track: NowPlayingTrack, toSong songId: String) -> Bool {
        guard let kept = unmatched(for: track) else { return false }
        let key = Draft.key(kind: .song, entityId: songId, entryId: nil)
        var draft = load(key: key) ?? Draft(entityId: songId, entityKind: .song, document: RichDocument(content: []), lenses: [], isPublic: kept.isPublic)
        let existing = draft.document.isBlank ? [] : draft.document.content
        let existingText = draft.document.plainText
        let additions = kept.document.content.filter { node in
            let text = RichDocument(content: [node]).plainText
            return !text.isEmpty && !existingText.contains(text)
        }
        draft.document = RichDocument(content: existing + additions)
        draft.lenses += kept.lenses.filter { !draft.lenses.contains($0) }
        draft.isPublic = draft.isPublic && kept.isPublic
        draft.updatedAt = Date()
        save(draft)
        delete(key: Draft.key(for: track))
        return true
    }

    /// Removes the draft for `key`: this person's and any unowned copy, so it can't come back.
    public func delete(key: String) {
        for url in urls(for: key) { try? FileManager.default.removeItem(at: url) }
    }

    /// Takes back words added earlier with `append` or `appendUnmatched` (the same text),
    /// such as an autosave about to be replaced or a note that was published after all.
    /// Only that run of paragraphs goes; everything else in the draft stays. A draft left
    /// with nothing in it is deleted.
    public func retract(_ text: String, fromKey key: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, var draft = load(key: key) else { return }
        let added = RichDocument.plain(words).content
        let content = draft.document.content
        guard added.count <= content.count,
              let start = (0...(content.count - added.count)).last(where: { Array(content[$0..<($0 + added.count)]) == added }) else { return }
        draft.document = RichDocument(content: Array(content[..<start]) + Array(content[(start + added.count)...]))
        if draft.document.isBlank, draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           draft.worked.isEmpty, draft.didntWork.isEmpty {
            delete(key: key)
        } else {
            draft.updatedAt = Date()
            save(draft)
        }
    }

    /// Every draft this store can see, newest first.
    public func all() -> [Draft] {
        recent(limit: .max) { _ in true }
    }

    /// The newest `limit` drafts this store can see (this person's and unowned ones) that
    /// pass `include`, decoding files newest first and stopping once enough are found.
    public func recent(limit: Int, where include: (Draft) -> Bool) -> [Draft] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let folders = owner == nil ? [root] : [directory, root]
        let files = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
        }
        let dated = files
            .filter { $0.pathExtension == "json" }
            .map { file in (file, (try? file.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        var found: [Draft] = []
        var seenKeys = Set<String>()
        for (file, _) in dated {
            guard found.count < limit else { break }
            guard let data = try? Data(contentsOf: file),
                  let draft = try? JSONDecoder().decode(Draft.self, from: data),
                  seenKeys.insert(draft.key).inserted,
                  include(draft) else { continue }
            found.append(draft)
        }
        return found.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func adding(_ words: String, lenses: [MusicLens], to existing: Draft?, otherwise make: () -> Draft) -> Draft {
        let addition = RichDocument.plain(words)
        guard var draft = existing else {
            var fresh = make()
            fresh.document = addition
            return fresh
        }
        let kept = draft.document.isBlank ? [] : draft.document.content
        draft.document = RichDocument(content: kept + addition.content)
        draft.lenses += lenses.filter { !draft.lenses.contains($0) }
        draft.updatedAt = Date()
        return draft
    }

    /// Where `key` may be: this person's folder first, then the unowned one.
    private func urls(for key: String) -> [URL] {
        owner == nil ? [url(for: key, in: root)] : [url(for: key, in: directory), url(for: key, in: root)]
    }

    private func url(for key: String, in folder: URL) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return folder.appending(path: "\(safe).json", directoryHint: .notDirectory)
    }
}
