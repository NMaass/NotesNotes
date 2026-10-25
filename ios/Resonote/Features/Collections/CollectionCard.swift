import ResonoteKit
import SwiftUI

/// A collection on a profile: a small fanned stack of its first covers, its name,
/// what holds it together, and how many pieces it holds.
struct CollectionCard: View {
    let collection: MusicCollection
    var showsPrivacy = false
    let onOpen: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let items = collection.items.sorted { $0.position < $1.position }
        let count = JournalCopy.count(items.count, "item")
        let isPrivate = showsPrivacy && !collection.isPublic
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: RN.Space.l) {
                CollectionArtStack(items: Array(items.prefix(4)), fallbackTitle: collection.name)
                VStack(alignment: .leading, spacing: RN.Space.xs) {
                    HStack(spacing: 6) {
                        Eyebrow("Collection")
                        if isPrivate {
                            Image(systemName: "lock")
                                .font(.caption2)
                                .foregroundStyle(RN.Palette.muted)
                        }
                    }
                    Text(collection.name)
                        .font(RN.Typography.headline)
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !collection.description.isEmpty {
                        Text(collection.description)
                            .font(.subheadline)
                            .foregroundStyle(RN.Palette.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(count)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(RN.Palette.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.muted)
            }
            .padding(RN.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(RoundedRectangle(cornerRadius: RN.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([collection.name, "collection", count, isPrivate ? "private" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(collection.description)
        .accessibilityAddTraits(.isButton)
    }
}

/// Up to four covers fanned like the web's art stack, inside a fixed square so
/// the card never changes size as covers load.
struct CollectionArtStack: View {
    let items: [CollectionItem]
    let fallbackTitle: String
    var size: CGFloat = 88

    @Environment(AppModel.self) private var model

    var body: some View {
        let artwork = size * 0.64
        let step = items.count > 1 ? (size - artwork) / CGFloat(items.count - 1) : 0
        ZStack(alignment: .topLeading) {
            if items.isEmpty {
                ArtworkView(nil, title: fallbackTitle, size: artwork)
                    .offset(x: (size - artwork) / 2, y: (size - artwork) / 2)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let entity = model.catalog.entity(kind: item.entityKind, id: item.entityId)
                    ArtworkView(
                        entity.flatMap { model.catalog.artworkURL(for: $0) },
                        title: entity?.name ?? "",
                        size: artwork,
                        cornerRadius: item.entityKind == .artist ? artwork / 2 : RN.Radius.artwork
                    )
                    .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    .rotationEffect(.degrees((Double(index) - 1.5) * 3))
                    .offset(x: CGFloat(index) * step, y: CGFloat(index) * step)
                }
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
