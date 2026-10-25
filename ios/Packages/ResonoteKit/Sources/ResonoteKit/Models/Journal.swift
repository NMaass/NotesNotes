import Foundation

/// One node of a Tiptap/ProseMirror JSON document. The web editor stores entries in
/// this shape (see docs/ARCHITECTURE.md), so native entries must produce it exactly.
public struct DocNode: Codable, Sendable, Hashable {
    public struct Mark: Codable, Sendable, Hashable {
        public var type: String
        public var attrs: [String: JSONValue]?

        public init(type: String, attrs: [String: JSONValue]? = nil) {
            self.type = type
            self.attrs = attrs
        }
    }

    public var type: String
    public var text: String?
    public var attrs: [String: JSONValue]?
    public var marks: [Mark]?
    public var content: [DocNode]?

    public init(type: String, text: String? = nil, attrs: [String: JSONValue]? = nil, marks: [Mark]? = nil, content: [DocNode]? = nil) {
        self.type = type
        self.text = text
        self.attrs = attrs
        self.marks = marks
        self.content = content
    }
}

/// `RichDocument` from the web app: `{ type: 'doc', content: [...] }`.
public struct RichDocument: Codable, Sendable, Hashable {
    public var type: String
    public var content: [DocNode]

    public init(content: [DocNode] = []) {
        self.type = "doc"
        self.content = content
    }

    private enum CodingKeys: String, CodingKey { case type, content }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "doc"
        content = try c.decodeIfPresent([DocNode].self, forKey: .content) ?? []
    }

    public static let empty = RichDocument(content: [DocNode(type: "paragraph")])
}

/// One inline mention of a catalog entity inside an entry, with its own identity.
public struct MusicReference: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var entityId: String
    public var entityKind: EntityKind
    public var label: String
    public var relation: RelationKind
    public var lenses: [MusicLens]

    public init(id: String, entityId: String, entityKind: EntityKind, label: String, relation: RelationKind = .mentions, lenses: [MusicLens] = []) {
        self.id = id
        self.entityId = entityId
        self.entityKind = entityKind
        self.label = label
        self.relation = relation
        self.lenses = lenses
    }

    private enum CodingKeys: String, CodingKey { case id, entityId, entityKind, label, relation, lenses }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        entityId = try c.decode(String.self, forKey: .entityId)
        entityKind = (try? c.decode(EntityKind.self, forKey: .entityKind)) ?? .song
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        relation = (try? c.decode(RelationKind.self, forKey: .relation)) ?? .mentions
        lenses = try c.decodeLossyArray(MusicLens.self, forKey: .lenses)
    }
}

public struct JournalEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var profileId: String
    public var entityId: String
    public var entityKind: EntityKind
    public var title: String?
    public var document: RichDocument
    public var plainText: String
    public var worked: String?
    public var didntWork: String?
    public var lenses: [MusicLens]
    public var references: [MusicReference]
    public var isPublic: Bool
    /// ISO-8601 from clients, or SQLite `YYYY-MM-DD HH:MM:SS` for server defaults. Parse with `ResonoteDate`.
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, profileId: String, entityId: String, entityKind: EntityKind, title: String? = nil, document: RichDocument, plainText: String, worked: String? = nil, didntWork: String? = nil, lenses: [MusicLens] = [], references: [MusicReference] = [], isPublic: Bool = true, createdAt: String, updatedAt: String) {
        self.id = id
        self.profileId = profileId
        self.entityId = entityId
        self.entityKind = entityKind
        self.title = title
        self.document = document
        self.plainText = plainText
        self.worked = worked
        self.didntWork = didntWork
        self.lenses = lenses
        self.references = references
        self.isPublic = isPublic
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileId, entityId, entityKind, title, document, plainText, worked, didntWork, lenses, references, updatedAt, createdAt
        case isPublic = "public"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? ""
        entityId = try c.decode(String.self, forKey: .entityId)
        entityKind = (try? c.decode(EntityKind.self, forKey: .entityKind)) ?? .song
        title = try c.decodeIfPresent(String.self, forKey: .title)
        document = (try? c.decode(RichDocument.self, forKey: .document)) ?? .empty
        plainText = try c.decodeIfPresent(String.self, forKey: .plainText) ?? ""
        worked = try c.decodeIfPresent(String.self, forKey: .worked)
        didntWork = try c.decodeIfPresent(String.self, forKey: .didntWork)
        lenses = try c.decodeLossyArray(MusicLens.self, forKey: .lenses)
        references = try c.decodeLossyArray(MusicReference.self, forKey: .references)
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? true
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct ListenLog: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var profileId: String
    public var songId: String
    public var moods: [String]
    public var note: String?
    public var listenedAt: String

    public init(id: String, profileId: String, songId: String, moods: [String], note: String? = nil, listenedAt: String) {
        self.id = id
        self.profileId = profileId
        self.songId = songId
        self.moods = moods
        self.note = note
        self.listenedAt = listenedAt
    }
}

public struct Like: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var profileId: String
    public var entityId: String
    public var entityKind: EntityKind
    public var clientVersion: Int
    public var createdAt: String

    public init(id: String, profileId: String, entityId: String, entityKind: EntityKind, clientVersion: Int, createdAt: String) {
        self.id = id
        self.profileId = profileId
        self.entityId = entityId
        self.entityKind = entityKind
        self.clientVersion = clientVersion
        self.createdAt = createdAt
    }
}

public struct CollectionItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var entityId: String
    public var entityKind: EntityKind
    public var note: String?
    public var position: Int

    public init(id: String, entityId: String, entityKind: EntityKind, note: String? = nil, position: Int) {
        self.id = id
        self.entityId = entityId
        self.entityKind = entityKind
        self.note = note
        self.position = position
    }
}

public struct MusicCollection: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var profileId: String
    public var name: String
    public var slug: String
    public var description: String
    public var isPublic: Bool
    public var items: [CollectionItem]
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, profileId: String, name: String, slug: String, description: String, isPublic: Bool, items: [CollectionItem], createdAt: String, updatedAt: String) {
        self.id = id
        self.profileId = profileId
        self.name = name
        self.slug = slug
        self.description = description
        self.isPublic = isPublic
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileId, name, slug, description, items, createdAt, updatedAt
        case isPublic = "public"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? ""
        name = try c.decode(String.self, forKey: .name)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        isPublic = try c.decodeIfPresent(Bool.self, forKey: .isPublic) ?? true
        items = try c.decodeLossyArray(CollectionItem.self, forKey: .items)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? createdAt
    }
}

public struct ProfilePin: Codable, Sendable, Hashable, Identifiable {
    public enum TargetType: String, Codable, Sendable { case entity, entry, collection }

    public var id: String
    public var profileId: String
    public var targetType: TargetType
    public var targetId: String
    public var position: Int

    public init(id: String, profileId: String, targetType: TargetType, targetId: String, position: Int) {
        self.id = id
        self.profileId = profileId
        self.targetType = targetType
        self.targetId = targetId
        self.position = position
    }
}

public struct Profile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var handle: String
    public var displayName: String
    public var bio: String
    public var avatarUrl: String?
    public var profileSongId: String?
    public var genreIds: [String]

    public init(id: String, handle: String, displayName: String, bio: String = "", avatarUrl: String? = nil, profileSongId: String? = nil, genreIds: [String] = []) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.bio = bio
        self.avatarUrl = avatarUrl
        self.profileSongId = profileSongId
        self.genreIds = genreIds
    }

    private enum CodingKeys: String, CodingKey { case id, handle, displayName, bio, avatarUrl, profileSongId, genreIds }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? handle
        bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        profileSongId = try c.decodeIfPresent(String.self, forKey: .profileSongId)
        genreIds = try c.decodeIfPresent([String].self, forKey: .genreIds) ?? []
    }
}

/// A person's data as the server ships it: the signed-in owner's bundle includes
/// private listens and entries; public bundles never include listens.
public struct ProfileBundle: Codable, Sendable, Hashable {
    public var profile: Profile
    public var likes: [Like]
    public var entries: [JournalEntry]
    public var listens: [ListenLog]
    public var collections: [MusicCollection]
    public var pins: [ProfilePin]
    public var genreAssertions: [EntityGenre]
    public var catalog: CatalogSlice

    public init(profile: Profile, likes: [Like] = [], entries: [JournalEntry] = [], listens: [ListenLog] = [], collections: [MusicCollection] = [], pins: [ProfilePin] = [], genreAssertions: [EntityGenre] = [], catalog: CatalogSlice = CatalogSlice()) {
        self.profile = profile
        self.likes = likes
        self.entries = entries
        self.listens = listens
        self.collections = collections
        self.pins = pins
        self.genreAssertions = genreAssertions
        self.catalog = catalog
    }

    private enum CodingKeys: String, CodingKey { case profile, likes, entries, listens, collections, pins, genreAssertions, catalog }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(Profile.self, forKey: .profile)
        likes = try c.decodeLossyArray(Like.self, forKey: .likes)
        entries = try c.decodeLossyArray(JournalEntry.self, forKey: .entries)
        listens = try c.decodeLossyArray(ListenLog.self, forKey: .listens)
        collections = try c.decodeLossyArray(MusicCollection.self, forKey: .collections)
        pins = try c.decodeLossyArray(ProfilePin.self, forKey: .pins)
        genreAssertions = try c.decodeLossyArray(EntityGenre.self, forKey: .genreAssertions)
        catalog = try c.decodeIfPresent(CatalogSlice.self, forKey: .catalog) ?? CatalogSlice()
    }
}

/// Parses the two timestamp shapes the backend emits.
public enum ResonoteDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    public static func parse(_ value: String) -> Date? {
        if let date = try? fractional.parse(value) { return date }
        if let date = try? whole.parse(value) { return date }
        // SQLite `datetime('now')` defaults: "YYYY-MM-DD HH:MM:SS" in UTC.
        let iso = value.replacingOccurrences(of: " ", with: "T") + "Z"
        return try? whole.parse(iso)
    }

    /// ISO-8601 with milliseconds, matching JavaScript's `Date.prototype.toISOString()`.
    public static func now() -> String { string(from: Date()) }

    public static func string(from date: Date) -> String { fractional.format(date) }
}
