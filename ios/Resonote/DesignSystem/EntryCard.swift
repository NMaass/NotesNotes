import ResonoteKit
import SwiftUI

/// Renders a stored Tiptap document as read-only prose. Music references become
/// rust links (`resonote://entity/...`) that the app's OpenURLAction routes. Takes
/// blocks prepared once per entry (`PreparedProse`), so a re-render does no JSON work.
struct RichDocumentView: View {
    let blocks: [Block]
    var font: Font = RN.Typography.prose

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(text)
                        .font(font)
                        .lineSpacing(5)
                        .foregroundStyle(RN.Palette.ink)
                        .tint(RN.Palette.rustText)
                case .quote(let text):
                    Text(text)
                        .font(font.italic())
                        .lineSpacing(5)
                        .foregroundStyle(RN.Palette.prose)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(RN.Palette.rust).frame(width: 2) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    enum Block: Sendable {
        case text(AttributedString)
        case quote(AttributedString)
    }

    /// Flattens the document into renderable blocks. Pure, so callers can precompute it.
    static func blocks(_ document: RichDocument) -> [Block] {
        var blocks: [Block] = []
        func inline(_ nodes: [DocNode]) -> AttributedString {
            var result = AttributedString()
            for node in nodes {
                switch node.type {
                case "text":
                    var piece = AttributedString(node.text ?? "")
                    let marks = Set((node.marks ?? []).map(\.type))
                    var intent: InlinePresentationIntent = []
                    if marks.contains("bold") { intent.insert(.stronglyEmphasized) }
                    if marks.contains("italic") { intent.insert(.emphasized) }
                    if marks.contains("code") { intent.insert(.code) }
                    if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                    result.append(piece)
                case "musicReference":
                    let label = node.attrs?["label"]?.stringValue ?? "music"
                    var piece = AttributedString(label)
                    if let id = node.attrs?["id"]?.stringValue,
                       let kind = node.attrs?["entityKind"]?.stringValue.flatMap(EntityKind.init(rawValue:)) {
                        piece.link = DeepLink.entity(kind: kind, id: id).url
                        piece.underlineStyle = .single
                    }
                    result.append(piece)
                case "hardBreak":
                    result.append(AttributedString("\n"))
                default:
                    result.append(inline(node.content ?? []))
                }
            }
            return result
        }
        func visit(_ node: DocNode, prefix: String?, quoted: Bool) {
            switch node.type {
            case "paragraph", "heading":
                var text = inline(node.content ?? [])
                if node.type == "heading" { text.inlinePresentationIntent = .stronglyEmphasized }
                if let prefix { text = AttributedString(prefix) + text }
                if !text.characters.isEmpty || !quoted { blocks.append(quoted ? .quote(text) : .text(text)) }
            case "bulletList":
                for item in node.content ?? [] { visit(item, prefix: "•  ", quoted: quoted) }
            case "orderedList":
                for (offset, item) in (node.content ?? []).enumerated() { visit(item, prefix: "\(offset + 1).  ", quoted: quoted) }
            case "listItem":
                for (offset, child) in (node.content ?? []).enumerated() { visit(child, prefix: offset == 0 ? prefix : nil, quoted: quoted) }
            case "blockquote":
                for child in node.content ?? [] { visit(child, prefix: nil, quoted: true) }
            default:
                blocks.append(.text(inline([node])))
            }
        }
        for node in document.content { visit(node, prefix: nil, quoted: false) }
        // Collapse empty paragraphs at the edges; keep interior spacing.
        while case .text(let first)? = blocks.first, first.characters.isEmpty { blocks.removeFirst() }
        while case .text(let last)? = blocks.last, last.characters.isEmpty { blocks.removeLast() }
        return blocks
    }
}

/// An entry's prose prepared for display: the blocks for the full page, a short
/// preview for feeds, and the date line. Built once per entry version.
struct PreparedProse {
    let blocks: [RichDocumentView.Block]
    /// The first blocks as one text, so a feed card clamps the whole entry to a few lines.
    let preview: AttributedString
    let date: Date?

    init(_ entry: JournalEntry) {
        let blocks = RichDocumentView.blocks(entry.document)
        self.blocks = blocks
        var preview = AttributedString()
        for (offset, block) in blocks.prefix(PreparedProse.previewBlocks).enumerated() {
            if offset > 0 { preview.append(AttributedString("\n\n")) }
            switch block {
            case .text(let text):
                preview.append(text)
            case .quote(let text):
                var quoted = text
                quoted.inlinePresentationIntent = .emphasized
                preview.append(quoted)
            }
        }
        self.preview = preview
        date = ResonoteDate.parse(entry.updatedAt)
    }

    private static let previewBlocks = 6

    /// Prepared prose by entry version, kept while memory allows.
    static func of(_ entry: JournalEntry) -> PreparedProse {
        let key = "\(entry.id)|\(entry.updatedAt)|\(entry.document.content.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit.prose }
        let prose = PreparedProse(entry)
        cache.setObject(Box(prose), forKey: key)
        return prose
    }

    private final class Box {
        let prose: PreparedProse
        init(_ prose: PreparedProse) { self.prose = prose }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 400
        return cache
    }()
}

/// A journal entry in a feed: who, about what, when, the writing, and its lenses.
/// VoiceOver reads it as one element that opens the entry; Report and Block are its
/// actions when it is someone else's.
struct EntryCard: View {
    let entry: JournalEntry
    let author: Profile?
    /// The entity the entry is about, shown when the feed spans many entities.
    var entity: CatalogEntity?
    var artworkURL: String?
    var onOpen: (() -> Void)?

    var body: some View {
        let prose = PreparedProse.of(entry)
        VStack(alignment: .leading, spacing: RN.Space.m) {
            header(date: prose.date)
            if let title = entry.title, !title.isEmpty {
                Text(title)
                    .font(RN.Typography.headline)
                    .foregroundStyle(RN.Palette.ink)
            }
            if onOpen == nil {
                RichDocumentView(blocks: prose.blocks)
            } else {
                Text(prose.preview)
                    .font(RN.Typography.prose)
                    .lineSpacing(5)
                    .foregroundStyle(RN.Palette.ink)
                    .tint(RN.Palette.rustText)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !entry.lenses.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.lenses, id: \.self) { lens in
                        Text(lens.rawValue)
                            .font(.caption)
                            .foregroundStyle(RN.Palette.muted)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(RN.Palette.line))
                    }
                }
            }
        }
        .padding(RN.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: RN.Radius.card))
        .onTapGesture { onOpen?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityAction { onOpen?() }
        .moderationActions(entry: entry, author: author)
    }

    private func header(date: Date?) -> some View {
        HStack(spacing: RN.Space.s) {
            if let entity {
                ArtworkView(artworkURL, title: entity.name, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(1)
                    meta(date: date)
                }
            } else {
                meta(date: date)
            }
            Spacer(minLength: 0)
            if !entry.isPublic {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
                    .accessibilityLabel("Private")
            }
        }
    }

    private func meta(date: Date?) -> some View {
        HStack(spacing: 4) {
            if let author { Text("@\(author.handle)") }
            if let date {
                if author != nil { Text("·").accessibilityHidden(true) }
                Text(date, format: .dateTime.month(.abbreviated).day().year())
            }
        }
        .font(.caption)
        .foregroundStyle(RN.Palette.muted)
        .lineLimit(1)
    }
}

/// A catalog row: artwork, name, subtitle, kind.
struct EntityRow: View {
    let entity: CatalogEntity
    var subtitle: String
    var artworkURL: String?
    var trailing: String?

    var body: some View {
        HStack(spacing: RN.Space.m) {
            ArtworkView(artworkURL ?? entity.imageUrl, title: entity.name, size: 46, cornerRadius: entity.kind == .artist ? 23 : RN.Radius.artwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text(subtitle.isEmpty ? entity.kind.label : subtitle)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(trailing ?? entity.kind.label)
                .font(.caption)
                .foregroundStyle(RN.Palette.muted)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
