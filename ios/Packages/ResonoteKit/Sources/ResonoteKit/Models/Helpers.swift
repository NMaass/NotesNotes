import Foundation

/// Identifier and slug conventions shared with the web app (src/lib/utils.ts).
public enum Identifiers {
    /// Lowercase UUID, matching `crypto.randomUUID()`.
    public static func make() -> String { UUID().uuidString.lowercased() }
}

public enum Slug {
    /// Mirrors `slugify` in src/lib/utils.ts.
    public static func make(_ value: String) -> String {
        let stripped = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
        var slug = ""
        var pendingDash = false
        for scalar in stripped.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return String(slug.prefix(80))
    }

    /// A slug not already in `taken`, using the web's "-2", "-3" suffixes.
    public static func unique(_ value: String, taken: Set<String>, fallback: String = "untitled-collection") -> String {
        let base = make(value).isEmpty ? fallback : make(value)
        guard taken.contains(base) else { return base }
        var attempt = 2
        while taken.contains("\(base)-\(attempt)") { attempt += 1 }
        return "\(base)-\(attempt)"
    }
}

extension RichDocument {
    /// One paragraph per non-empty line — for quick notes written outside the composer.
    public static func plain(_ text: String) -> RichDocument {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { DocNode(type: "paragraph", content: [DocNode(type: "text", text: $0)]) }
        return RichDocument(content: paragraphs.isEmpty ? [DocNode(type: "paragraph")] : paragraphs)
    }

    /// The document's text, with references rendered as their labels (Tiptap's `getText()`).
    public var plainText: String {
        func text(of node: DocNode) -> String {
            switch node.type {
            case "text": return node.text ?? ""
            case "musicReference": return node.attrs?["label"]?.stringValue ?? ""
            case "hardBreak": return "\n"
            default: return (node.content ?? []).map(text(of:)).joined()
            }
        }
        return content.map(text(of:)).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every inline music reference, in document order (the web's `referencesFromDocument`).
    public var references: [MusicReference] {
        var found: [MusicReference] = []
        func walk(_ nodes: [DocNode]) {
            for node in nodes {
                if node.type == "musicReference",
                   let entityId = node.attrs?["id"]?.stringValue,
                   let kind = node.attrs?["entityKind"]?.stringValue.flatMap(EntityKind.init(rawValue:)) {
                    found.append(MusicReference(
                        id: node.attrs?["referenceId"]?.stringValue ?? Identifiers.make(),
                        entityId: entityId,
                        entityKind: kind,
                        label: node.attrs?["label"]?.stringValue ?? "",
                        relation: node.attrs?["relation"]?.stringValue.flatMap(RelationKind.init(rawValue:)) ?? .mentions,
                        lenses: (node.attrs?["lenses"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(MusicLens.init(rawValue:)) }
                    ))
                }
                walk(node.content ?? [])
            }
        }
        walk(content)
        return found
    }

    public var isBlank: Bool { plainText.isEmpty }
}
