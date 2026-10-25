import SwiftUI

/// The inline music reference carried by a run of editor text. Mirrors the web
/// editor's `musicReference` node attributes (src/components/journal/music-reference-extension.ts).
public struct MusicRefValue: Codable, Hashable, Sendable {
    /// Identifies this particular mention; two mentions of one song stay distinct.
    public var referenceId: String
    public var entityId: String
    public var label: String
    public var entityKind: EntityKind
    public var relation: RelationKind
    public var lenses: [MusicLens]

    public init(referenceId: String = Identifiers.make(), entityId: String, label: String, entityKind: EntityKind, relation: RelationKind = .mentions, lenses: [MusicLens] = []) {
        self.referenceId = referenceId
        self.entityId = entityId
        self.label = label
        self.entityKind = entityKind
        self.relation = relation
        self.lenses = lenses
    }

    public var reference: MusicReference {
        MusicReference(id: referenceId, entityId: entityId, entityKind: entityKind, label: label, relation: relation, lenses: lenses)
    }
}

public enum MusicRefAttribute: CodableAttributedStringKey {
    public typealias Value = MusicRefValue
    public static let name = "resonote.musicRef"
    /// Typing right after a reference must not extend it.
    public static let inheritedByAddedText = false
}

extension AttributeScopes {
    public struct ResonoteAttributes: AttributeScope {
        public let musicRef: MusicRefAttribute
        public let swiftUI: SwiftUIAttributes
    }

    public var resonote: ResonoteAttributes.Type { ResonoteAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.ResonoteAttributes, T>) -> T {
        self[T.self]
    }
}

/// Restricts the composer to what Resonote notes support and styles references.
/// Apply with `.attributedTextFormattingDefinition(NoteFormatting(referenceColor:))`.
public struct NoteFormatting: AttributedTextFormattingDefinition {
    public struct Scope: AttributeScope {
        public let font: AttributeScopes.SwiftUIAttributes.FontAttribute
        public let foregroundColor: AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
        public let underlineStyle: AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
        public let strikethroughStyle: AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute
        public let musicRef: MusicRefAttribute
    }

    public var referenceColor: Color

    public init(referenceColor: Color) {
        self.referenceColor = referenceColor
    }

    public var body: some AttributedTextFormattingDefinition<Scope> {
        ValueConstraint(for: \.strikethroughStyle, values: [nil], default: nil)
        ReferenceTint(color: referenceColor)
        ReferenceUnderline()
    }
}

private struct ReferenceTint: AttributedTextValueConstraint {
    typealias Scope = NoteFormatting.Scope
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute

    var color: Color

    func constrain(_ container: inout Attributes) {
        container.foregroundColor = container.musicRef != nil ? color : nil
    }
}

private struct ReferenceUnderline: AttributedTextValueConstraint {
    typealias Scope = NoteFormatting.Scope
    typealias AttributeKey = AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute

    func constrain(_ container: inout Attributes) {
        container.underlineStyle = container.musicRef != nil ? .single : nil
    }
}

/// Converts between the composer's `AttributedString` and the web's Tiptap JSON,
/// and implements the `\` reference trigger and whole-token deletion.
///
/// Native notes support paragraphs, bold, italic, and music references. Web
/// entries with headings, lists, or quotes open flattened into paragraphs, and
/// `RichDocument.hasBlocksBeyondParagraphs` lets the composer say so first.
public enum RichTextCodec {
    public struct Trigger: Equatable {
        public var range: Range<AttributedString.Index>
        public var query: String
    }

    // MARK: Document → editor

    /// - Parameters:
    ///   - bold/italic: fonts to apply to marked runs, usually the editor's body font `.bold()` / `.italic()`.
    public static func editableText(from document: RichDocument, bold: Font? = nil, italic: Font? = nil) -> AttributedString {
        var result = AttributedString()
        let blocks = flattenBlocks(document.content)
        for (index, inline) in blocks.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            for node in inline {
                result.append(attributed(inline: node, bold: bold, italic: italic))
            }
        }
        return result
    }

    private static func attributed(inline node: DocNode, bold: Font?, italic: Font?) -> AttributedString {
        switch node.type {
        case "text":
            var piece = AttributedString(node.text ?? "")
            let marks = Set((node.marks ?? []).map(\.type))
            if marks.contains("bold"), marks.contains("italic"), let bold {
                piece.font = bold.italic()
            } else if marks.contains("bold"), let bold {
                piece.font = bold
            } else if marks.contains("italic"), let italic {
                piece.font = italic
            }
            return piece
        case "musicReference":
            guard let ref = refValue(from: node) else {
                return AttributedString(node.attrs?["label"]?.stringValue ?? "")
            }
            var token = AttributedString(ref.label)
            token.musicRef = ref
            return token
        case "hardBreak":
            return AttributedString("\n")
        default:
            var nested = AttributedString()
            for child in node.content ?? [] { nested.append(attributed(inline: child, bold: bold, italic: italic)) }
            return nested
        }
    }

    /// Every block becomes a line of inline nodes; list items get a bullet so meaning survives.
    private static func flattenBlocks(_ nodes: [DocNode]) -> [[DocNode]] {
        var lines: [[DocNode]] = []
        func visit(_ node: DocNode, prefix: String?) {
            switch node.type {
            case "paragraph", "heading":
                var inline = node.content ?? []
                if let prefix { inline.insert(DocNode(type: "text", text: prefix), at: 0) }
                lines.append(inline)
            case "bulletList":
                for item in node.content ?? [] { visit(item, prefix: "• ") }
            case "orderedList":
                for (offset, item) in (node.content ?? []).enumerated() { visit(item, prefix: "\(offset + 1). ") }
            case "listItem", "blockquote":
                var first = true
                for child in node.content ?? [] {
                    visit(child, prefix: first ? prefix : nil)
                    first = false
                }
            default:
                lines.append([node])
            }
        }
        for node in nodes { visit(node, prefix: nil) }
        return lines.isEmpty ? [[]] : lines
    }

    // MARK: Editor → document

    /// - Parameter fontContext: `@Environment(\.fontResolutionContext)`, used to detect bold and italic.
    public static func document(from text: AttributedString, fontContext: Font.Context? = nil) -> RichDocument {
        var paragraphs: [DocNode] = []
        var current: [DocNode] = []

        func appendText(_ value: String, marks: [String]) {
            guard !value.isEmpty else { return }
            let markNodes = marks.isEmpty ? nil : marks.map { DocNode.Mark(type: $0) }
            if var last = current.last, last.type == "text", last.marks == markNodes {
                last.text = (last.text ?? "") + value
                current[current.count - 1] = last
            } else {
                current.append(DocNode(type: "text", text: value, marks: markNodes))
            }
        }

        func closeParagraph() {
            paragraphs.append(DocNode(type: "paragraph", content: current.isEmpty ? nil : current))
            current = []
        }

        for run in text.runs {
            let value = String(text.characters[run.range])
            if let ref = run.musicRef {
                current.append(node(for: ref, label: value.isEmpty ? ref.label : value))
                continue
            }
            let marks = Self.marks(of: run, fontContext: fontContext)
            let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if index > 0 { closeParagraph() }
                appendText(String(line), marks: marks)
            }
        }
        closeParagraph()

        // Drop trailing empty paragraphs the way Tiptap would keep at most one.
        while paragraphs.count > 1, paragraphs.last?.content == nil { paragraphs.removeLast() }
        return RichDocument(content: paragraphs)
    }

    private static func marks(of run: AttributedString.Runs.Run, fontContext: Font.Context?) -> [String] {
        var bold = false
        var italic = false
        if let intent = run.inlinePresentationIntent {
            bold = intent.contains(.stronglyEmphasized)
            italic = intent.contains(.emphasized)
        }
        if let fontContext, let font = run.font {
            let resolved = font.resolve(in: fontContext)
            bold = bold || resolved.isBold
            italic = italic || resolved.isItalic
        }
        return (bold ? ["bold"] : []) + (italic ? ["italic"] : [])
    }

    static func node(for ref: MusicRefValue, label: String) -> DocNode {
        DocNode(type: "musicReference", attrs: [
            "referenceId": .string(ref.referenceId),
            "id": .string(ref.entityId),
            "label": .string(label),
            "entityKind": .string(ref.entityKind.rawValue),
            "relation": .string(ref.relation.rawValue),
            "lenses": .array(ref.lenses.map { .string($0.rawValue) }),
        ])
    }

    static func refValue(from node: DocNode) -> MusicRefValue? {
        guard let attrs = node.attrs,
              let entityId = attrs["id"]?.stringValue,
              let kind = attrs["entityKind"]?.stringValue.flatMap(EntityKind.init(rawValue:)) else { return nil }
        return MusicRefValue(
            referenceId: attrs["referenceId"]?.stringValue ?? Identifiers.make(),
            entityId: entityId,
            label: attrs["label"]?.stringValue ?? "",
            entityKind: kind,
            relation: attrs["relation"]?.stringValue.flatMap(RelationKind.init(rawValue:)) ?? .mentions,
            lenses: (attrs["lenses"]?.arrayValue ?? []).compactMap { $0.stringValue.flatMap(MusicLens.init(rawValue:)) }
        )
    }

    // MARK: References

    /// References in document order, one per token.
    public static func references(in text: AttributedString) -> [MusicReference] {
        text.runs[\.musicRef].compactMap { value, _ in value?.reference }
    }

    /// Changes one reference's relation or lenses without touching its text.
    public static func updateReference(_ referenceId: String, relation: RelationKind? = nil, lenses: [MusicLens]? = nil, in text: inout AttributedString) {
        let ranges = text.runs[\.musicRef].compactMap { value, range -> (MusicRefValue, Range<AttributedString.Index>)? in
            guard let value, value.referenceId == referenceId else { return nil }
            return (value, range)
        }
        for (value, range) in ranges {
            var updated = value
            if let relation { updated.relation = relation }
            if let lenses { updated.lenses = lenses }
            text[range].musicRef = updated
        }
    }

    // MARK: The `\` trigger

    /// The `\query` immediately before the caret, if the person is typing a reference.
    public static func activeTrigger(in text: AttributedString, selection: AttributedTextSelection) -> Trigger? {
        guard case .insertionPoint(let caret) = selection.indices(in: text) else { return nil }
        let characters = text.characters
        var index = caret
        var scanned = 0
        while index > characters.startIndex, scanned < 64 {
            let previous = characters.index(before: index)
            let character = characters[previous]
            if character == "\\" {
                if text[previous..<caret].runs[\.musicRef].contains(where: { $0.0 != nil }) { return nil }
                let query = String(characters[characters.index(after: previous)..<caret])
                return Trigger(range: previous..<caret, query: query)
            }
            if character.isNewline { return nil }
            index = previous
            scanned += 1
        }
        return nil
    }

    /// Replaces the trigger with a reference token and a trailing space, leaving the caret after it.
    public static func insert(_ ref: MusicRefValue, replacing range: Range<AttributedString.Index>, in text: inout AttributedString, selection: inout AttributedTextSelection) {
        var token = AttributedString(ref.label)
        token.musicRef = ref
        var insertion = token
        insertion.append(AttributedString(" "))
        selection = AttributedTextSelection(range: range)
        text.replaceSelection(&selection, with: insertion)
        collapseToEnd(&selection, in: text)
    }

    /// Inserts a reference at the caret (from a toolbar button rather than `\`).
    public static func insertAtSelection(_ ref: MusicRefValue, in text: inout AttributedString, selection: inout AttributedTextSelection) {
        var token = AttributedString(ref.label)
        token.musicRef = ref
        var insertion = token
        insertion.append(AttributedString(" "))
        text.replaceSelection(&selection, with: insertion)
        collapseToEnd(&selection, in: text)
    }

    /// After replacing a range, leave a caret after the new content so typing never overwrites it.
    private static func collapseToEnd(_ selection: inout AttributedTextSelection, in text: AttributedString) {
        if case .ranges(let ranges) = selection.indices(in: text), let end = ranges.ranges.last?.upperBound {
            selection = AttributedTextSelection(insertionPoint: end)
        }
    }

    /// Removes any reference whose text was partially edited, so references are deleted
    /// whole, and gives pasted duplicates their own identity. Returns whether anything changed.
    @discardableResult
    public static func enforceAtomicReferences(in text: inout AttributedString, selection: inout AttributedTextSelection) -> Bool {
        var removal = RangeSet<AttributedString.Index>()
        var reidentified: [(Range<AttributedString.Index>, MusicRefValue)] = []
        var seen = Set<String>()
        for (value, range) in text.runs[\.musicRef] {
            guard let value else { continue }
            if String(text.characters[range]) != value.label {
                removal.insert(contentsOf: range)
            } else if !seen.insert(value.referenceId).inserted {
                var fresh = value
                fresh.referenceId = Identifiers.make()
                reidentified.append((range, fresh))
            }
        }
        guard !removal.isEmpty || !reidentified.isEmpty else { return false }
        text.transform(updating: &selection) { text in
            for (range, value) in reidentified { text[range].musicRef = value }
            for range in removal.ranges.reversed() { text.removeSubrange(range) }
        }
        return true
    }
}

extension RichDocument {
    /// Whether the document uses structure the native composer flattens (headings, lists, quotes).
    public var hasBlocksBeyondParagraphs: Bool {
        content.contains { $0.type != "paragraph" }
    }
}
