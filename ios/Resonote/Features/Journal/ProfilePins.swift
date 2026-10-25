import ResonoteKit
import SwiftUI

/// "Pinned / Start here": what a person put first on their page.
struct ProfilePinsView: View {
    let bundle: ProfileBundle
    let isOwner: Bool
    /// Catalog rows that could not be loaded, so their pins stop waiting.
    var unavailable: Set<String> = []

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    private enum Pinned: Identifiable {
        case entry(JournalEntry)
        case collection(MusicCollection)
        case entity(CatalogEntity)
        /// Pinned music this device hasn't loaded yet: a card of the final size holds its place.
        case loading(String)

        var id: String {
            switch self {
            case .entry(let entry): "entry-\(entry.id)"
            case .collection(let collection): "collection-\(collection.id)"
            case .entity(let entity): "entity-\(entity.id)"
            case .loading(let id): "entity-\(id)"
            }
        }
    }

    var body: some View {
        let items = pinned
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: RN.Space.m) {
                SectionHeader(eyebrow: "Pinned", title: "Start here")
                ForEach(items) { item in
                    switch item {
                    case .entry(let entry):
                        let entity = model.catalog.entity(kind: entry.entityKind, id: entry.entityId)
                        EntryCard(
                            entry: entry,
                            author: bundle.profile,
                            entity: entity,
                            artworkURL: entity.flatMap { model.catalog.artworkURL(for: $0) },
                            onOpen: { router.push(.entry(id: entry.id)) }
                        )
                    case .collection(let collection):
                        CollectionCard(collection: collection, showsPrivacy: isOwner) {
                            router.push(.collection(handle: bundle.profile.handle, id: collection.id))
                        }
                    case .entity(let entity):
                        PinnedEntityCard(entity: entity)
                    case .loading:
                        CatalogRowPlaceholder(artworkSize: 56)
                            .padding(RN.Space.l)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface()
                    }
                }
            }
        }
    }

    /// Pins in their saved order, skipping anything this viewer can't see or this
    /// device can't name.
    private var pinned: [Pinned] {
        bundle.pins
            .sorted { $0.position < $1.position }
            .compactMap { pin -> Pinned? in
                switch pin.targetType {
                case .entry:
                    guard let entry = bundle.entries.first(where: { $0.id == pin.targetId }), isOwner || entry.isPublic else { return nil }
                    return .entry(entry)
                case .collection:
                    guard let collection = bundle.collections.first(where: { $0.id == pin.targetId }), isOwner || collection.isPublic else { return nil }
                    return .collection(collection)
                case .entity:
                    if let entity = model.catalog.entity(id: pin.targetId) { return .entity(entity) }
                    return unavailable.contains(pin.targetId) ? nil : .loading(pin.targetId)
                }
            }
    }
}

private struct PinnedEntityCard: View {
    let entity: CatalogEntity

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            router.push(.entity(kind: entity.kind, id: entity.id))
        } label: {
            HStack(spacing: RN.Space.m) {
                ArtworkView(
                    model.catalog.artworkURL(for: entity),
                    title: entity.name,
                    size: 56,
                    cornerRadius: entity.kind == .artist ? 28 : RN.Radius.artwork
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.kind.label)
                        .font(.caption)
                        .foregroundStyle(RN.Palette.muted)
                    Text(entity.name)
                        .font(RN.Typography.headline)
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(2)
                    let subtitle = model.catalog.subtitle(for: entity)
                    if !subtitle.isEmpty, entity.kind != .genre, entity.kind != .artist {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(RN.Palette.muted)
                            .lineLimit(1)
                    }
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
        .accessibilityElement(children: .combine)
    }
}
