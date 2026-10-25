import ResonoteKit
import SwiftUI

/// One collection: its name and reason, then its music in order. The owner can
/// rename it, change who sees it, reorder and remove items, or delete it.
struct CollectionView: View {
    let handle: String
    let collectionId: String

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    private enum LoadState: Equatable {
        case idle, loading, missing
        case failed(String)
    }

    @State private var publicBundle: ProfileBundle?
    @State private var loadState: LoadState = .idle
    @State private var unavailable: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var confirmDelete = false
    @State private var pinTaps = 0
    /// Kept while the screen pops after a delete, so it never flashes "not found".
    @State private var deletedSnapshot: MusicCollection?

    init(handle: String, collectionId: String) {
        self.handle = handle
        self.collectionId = collectionId
        _publicBundle = State(initialValue: PublicProfileCache.bundle(handle: handle))
    }

    private var ownCollection: MusicCollection? {
        model.bundle?.collections.first { $0.id == collectionId }
    }

    private var collection: MusicCollection? {
        ownCollection ?? publicBundle?.collections.first { $0.id == collectionId } ?? deletedSnapshot
    }

    private var isOwner: Bool { ownCollection != nil }

    private var ownerProfile: Profile? {
        isOwner ? model.profile : publicBundle?.profile
    }

    var body: some View {
        Group {
            if let collection {
                content(collection)
            } else {
                fallback
            }
        }
        .paperBackground()
        .navigationTitle(collection?.name ?? "Collection")
        .navigationBarTitleDisplayMode(.inline)
        // The header already shows the name in large type; the title stays for history and VoiceOver.
        .toolbar(removing: .title)
        .toolbar { toolbar }
        .task(id: handle) { await loadIfNeeded() }
        .confirmationDialog("Delete this collection?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete collection", role: .destructive, action: deleteCollection)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The collection and its order are removed. The music stays in Resonote.")
        }
    }

    // MARK: Content

    private func content(_ collection: MusicCollection) -> some View {
        let items = collection.items.sorted { $0.position < $1.position }
        let moveAction: ((IndexSet, Int) -> Void)? = isOwner ? { move(items, from: $0, to: $1) } : nil
        let deleteAction: ((IndexSet) -> Void)? = isOwner ? { remove(items, at: $0) } : nil
        return List {
            header(collection, count: items.count)
                .listRowInsets(EdgeInsets(top: RN.Space.l, leading: RN.Space.gutter, bottom: RN.Space.xl, trailing: RN.Space.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if items.isEmpty {
                EmptyStateView(
                    title: "This collection is empty",
                    message: "Add music from any artist, album, song, or genre page."
                )
                .listRowInsets(EdgeInsets(top: 0, leading: RN.Space.gutter, bottom: 0, trailing: RN.Space.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item, index: index, collectionId: collection.id)
                        .listRowInsets(EdgeInsets(top: RN.Space.s, leading: RN.Space.gutter, bottom: RN.Space.s, trailing: RN.Space.gutter))
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(RN.Palette.line)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if isOwner {
                                Button(role: .destructive) {
                                    model.removeItem(item.id, fromCollection: collection.id)
                                } label: {
                                    Label("Remove", systemImage: "minus.circle")
                                }
                            }
                        }
                }
                .onMove(perform: moveAction)
                .onDelete(perform: deleteAction)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .refreshable { await refresh() }
        .loadsMissingCatalog(items.map { CatalogRef(kind: $0.entityKind, id: $0.entityId) }, unavailable: $unavailable)
    }

    private func header(_ collection: MusicCollection, count: Int) -> some View {
        let isPinned = model.isPinned(.collection, collection.id)
        return VStack(alignment: .leading, spacing: RN.Space.m) {
            Eyebrow("@\(ownerProfile?.handle ?? ProfileHandle.normalize(handle))’s collection")
            Text(collection.name)
                .font(RN.Typography.display)
                .foregroundStyle(RN.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !collection.description.isEmpty {
                Text(collection.description)
                    .font(RN.Typography.prose)
                    .foregroundStyle(RN.Palette.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: RN.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(JournalCopy.count(count, "piece of music", "pieces of music"))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(RN.Palette.muted)
                    if isOwner, !collection.isPublic {
                        Label("Only you can see this", systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(RN.Palette.muted)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    pinTaps += 1
                    model.togglePin(.collection, collection.id)
                } label: {
                    Label {
                        StableLabel(isPinned ? "Pinned" : "Pin", among: ["Pin", "Pinned"])
                    } icon: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                    }
                }
                .buttonStyle(.outline)
                .sensoryFeedback(.selection, trigger: pinTaps)
                .accessibilityLabel(isPinned ? "Pinned to your profile" : "Pin to your profile")
                .accessibilityAddTraits(isPinned ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ item: CollectionItem, index: Int, collectionId: String) -> some View {
        if let entity = model.catalog.entity(kind: item.entityKind, id: item.entityId) {
            NavigationLink(value: Route.entity(kind: entity.kind, id: entity.id)) {
                CollectionItemRow(index: index, entity: entity, note: item.note)
            }
        } else {
            HStack(spacing: RN.Space.m) {
                CollectionIndexLabel(index: index)
                CatalogRowPlaceholder(artworkSize: 52, isUnavailable: unavailable.contains(item.entityId))
            }
        }
    }

    // MARK: Fallback states

    @ViewBuilder
    private var fallback: some View {
        ScrollView {
            Group {
                switch loadState {
                case .idle, .loading:
                    CollectionPlaceholder()
                case .missing:
                    EmptyStateView(title: "Collection not found", message: "It may have been removed or made private.")
                case .failed(let message):
                    EmptyStateView(title: "Couldn't load this collection", message: message, actionTitle: "Try again") {
                        Task { await load(force: true) }
                    }
                }
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.vertical, RN.Space.l)
        }
        .refreshable { await load(force: true) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let ownCollection {
            if editMode.isEditing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { withAnimation { editMode = .inactive } }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Edit details", systemImage: "pencil") { router.present(.editCollection(id: collectionId)) }
                        Button("Reorder", systemImage: "arrow.up.arrow.down") { withAnimation { editMode = .active } }
                            .disabled(ownCollection.items.count < 2)
                        Divider()
                        Button("Delete collection", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("Collection options", systemImage: "ellipsis")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func move(_ items: [CollectionItem], from source: IndexSet, to destination: Int) {
        guard var latest = ownCollection else { return }
        var reordered = items
        reordered.move(fromOffsets: source, toOffset: destination)
        latest.items = reordered
        model.updateCollection(latest)
    }

    private func remove(_ items: [CollectionItem], at offsets: IndexSet) {
        for index in offsets where items.indices.contains(index) {
            model.removeItem(items[index].id, fromCollection: collectionId)
        }
    }

    private func deleteCollection() {
        guard let ownCollection else { return }
        deletedSnapshot = ownCollection
        dismiss()
        model.deleteCollection(id: ownCollection.id)
    }

    private func refresh() async {
        if isOwner {
            await model.refreshSession()
        } else {
            await load(force: true)
        }
    }

    private func loadIfNeeded() async {
        guard ownCollection == nil else { return }
        if model.isOwnHandle(handle) {
            // Possibly made on the web since the last refresh.
            loadState = .loading
            await model.refreshSession()
            if ownCollection == nil { loadState = .missing }
            return
        }
        // Coming back to the page reuses a copy loaded in the last minute or so.
        await load(force: false)
    }

    /// Loads the owner's public page. A refresh keeps what is on screen until the new copy arrives.
    private func load(force: Bool) async {
        if publicBundle == nil { loadState = .loading }
        do {
            let bundle = try await model.loadPublicBundle(handle: handle, force: force)
            publicBundle = bundle
            loadState = bundle.collections.contains { $0.id == collectionId } ? .idle : .missing
        } catch is CancellationError {
            return
        } catch APIError.server(status: 404, _) {
            loadState = .missing
        } catch {
            guard publicBundle == nil else { return }
            loadState = .failed((error as? APIError)?.errorDescription ?? "Resonote can't be reached right now.")
        }
    }
}

/// "01", "02" … in the serif numerals the web uses.
private struct CollectionIndexLabel: View {
    let index: Int

    var body: some View {
        Text(JournalCopy.ordinal(index))
            .font(RN.Typography.serif(19, relativeTo: .headline).monospacedDigit())
            .foregroundStyle(RN.Palette.muted)
            .frame(minWidth: 28, alignment: .leading)
            .accessibilityHidden(true)
    }
}

private struct CollectionItemRow: View {
    let index: Int
    let entity: CatalogEntity
    let note: String?

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: RN.Space.m) {
            CollectionIndexLabel(index: index)
            ArtworkView(
                model.catalog.artworkURL(for: entity),
                title: entity.name,
                size: 52,
                cornerRadius: entity.kind == .artist ? 26 : RN.Radius.artwork
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.kind.label.uppercased())
                    .font(RN.Typography.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(RN.Palette.rustText)
                Text(entity.name)
                    .font(RN.Typography.headline)
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(2)
                let subtitle = model.catalog.subtitle(for: entity)
                if entity.kind == .song || entity.kind == .album, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(1)
                }
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.prose)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index + 1). \(entity.name), \(entity.kind.label)")
        .accessibilityHint(note ?? "")
    }
}

/// The collection header and three rows at their final size while the page loads.
private struct CollectionPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            Eyebrow("Loading collection")
            Text("Collection name")
                .font(RN.Typography.display)
                .redacted(reason: .placeholder)
            Text("What holds these pieces of music together.")
                .font(RN.Typography.prose)
                .redacted(reason: .placeholder)
            Text("0 pieces of music")
                .font(.subheadline)
                .redacted(reason: .placeholder)
                .padding(.bottom, RN.Space.l)
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: RN.Space.m) {
                    CollectionIndexLabel(index: index)
                    CatalogRowPlaceholder(artworkSize: 52)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading collection")
    }
}
