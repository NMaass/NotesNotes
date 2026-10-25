import Foundation

/// The four kinds of catalog entity a person can write about. Mirrors `EntityKind` in src/lib/data/types.ts.
public enum EntityKind: String, Codable, Sendable, CaseIterable, Hashable {
    case artist, album, song, genre

    public var label: String {
        switch self {
        case .artist: "Artist"
        case .album: "Album"
        case .song: "Song"
        case .genre: "Genre"
        }
    }
}

/// What part of the music an observation attends to. Mirrors `MusicLens`.
public enum MusicLens: String, Codable, Sendable, CaseIterable, Hashable {
    case feeling, lyrics, composition, performance, production, context
}

/// How an inline reference relates to the entry's subject. Mirrors `RelationKind`.
public enum RelationKind: String, Codable, Sendable, CaseIterable, Hashable {
    case mentions
    case remindsMeOf = "reminds-me-of"
    case pairsWith = "pairs-with"
    case contrastsWith = "contrasts-with"
    case influencedBy = "influenced-by"

    /// Labels match the web editor's relation chips.
    public var label: String {
        switch self {
        case .mentions: "linked in passing"
        case .remindsMeOf: "reminds me of"
        case .pairsWith: "pairs with"
        case .contrastsWith: "contrasts with"
        case .influencedBy: "influenced by"
        }
    }
}

/// Shared writing vocabulary, kept identical to the web app so both clients offer the same words.
public enum Vocabulary {
    /// Listen moods from src/components/music/listen-dialog.tsx.
    public static let moods = ["restless", "warm", "euphoric", "heavy", "lonely", "focused", "nostalgic", "weightless"]

    /// Writing prompts from src/components/journal/journal-editor.tsx.
    public static let prompts = [
        "Where did this song take you?",
        "What did you notice this time?",
        "When did you first hear this?",
        "What does this take you back to?",
        "Did you used to dislike this? What changed?",
        "What does the performance do that the lyrics do not?",
        "What production choice keeps pulling your attention?",
        "What would you play immediately after this?",
        "What is hard to explain about this music?",
    ]
}

/// Decodes an array while skipping elements that fail to decode, so one unknown
/// lens or relation from a newer server never drops a whole entry.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(DiscardedValue.self)
            }
        }
        self.elements = elements
    }

    /// Accepts any JSON value without inspecting it, which advances the unkeyed container.
    private struct DiscardedValue: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

extension KeyedDecodingContainer {
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        try decodeIfPresent(LossyArray<T>.self, forKey: key)?.elements ?? []
    }
}
