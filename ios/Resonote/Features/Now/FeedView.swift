import ResonoteKit
import SwiftUI

/// Writing others have chosen to publish, newest first. A place to read, reached from
/// the Now tab; it is never the home screen, and there is no follow graph behind it.
struct FeedView: View {
    @Environment(AppModel.self) private var model
    @State private var feed = NowFeed()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RN.Space.l) {
                FeedSection(feed: feed)
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.bottom, RN.Space.xxl)
        }
        .paperBackground()
        .navigationTitle("Published")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await feed.reload(model: model) }
        .task { await feed.appear(model: model) }
    }
}

// MARK: - Feed

/// "Published by others": its children sit directly in the page's lazy stack, so
/// cards are built only as they scroll into view.
private struct FeedSection: View {
    let feed: NowFeed

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    private static let skeletonCount = 3

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            SectionHeader(eyebrow: "Published by others", title: "Writing, not scoring")
            // New writing waits here, in the header's own line, instead of pushing cards down.
            if feed.newCount > 0 {
                Button(feed.newCount == 1 ? "1 new" : "\(feed.newCount) new") {
                    feed.showNew()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RN.Palette.rustText)
                .accessibilityHint("Shows the newest writing at the top")
            }
        }
        .padding(.top, RN.Space.s)

        let entries = feed.entries.filter { !model.isBlocked($0.profileId) }
        if entries.isEmpty {
            switch feed.status {
            case .idle, .loading:
                ForEach(0..<Self.skeletonCount, id: \.self) { index in
                    NowEntrySkeleton(announces: index == 0)
                }
            case .failed:
                NowFeedErrorRow {
                    Task { await feed.reload(model: model) }
                }
            case .loaded:
                EmptyStateView(
                    title: "Nothing published yet",
                    message: "When people choose to publish what they wrote, it appears here. Your own writing stays private until you publish it."
                )
            }
        } else {
            let lastId = entries.last?.id
            ForEach(entries) { entry in
                card(for: entry)
                    .onAppear {
                        guard entry.id == lastId else { return }
                        Task { await feed.loadMore(model: model) }
                    }
            }
            if feed.nextCursor != nil {
                footer
            }
        }
    }

    private func card(for entry: JournalEntry) -> some View {
        let entity = model.catalog.entity(kind: entry.entityKind, id: entry.entityId)
        return EntryCard(
            entry: entry,
            author: model.author(of: entry),
            entity: entity,
            artworkURL: entity.flatMap { model.catalog.artworkURL(for: $0) },
            onOpen: { router.push(.entry(id: entry.id)) }
        )
    }

    /// Reserved height whether it is loading, failed, or waiting for the last card.
    private var footer: some View {
        ZStack {
            ProgressView()
                .nowStateLayer(visible: feed.isLoadingMore)
            HStack(spacing: RN.Space.s) {
                Text("More writing didn't load.")
                    .foregroundStyle(RN.Palette.muted)
                Button("Retry") {
                    Task { await feed.loadMore(model: model) }
                }
                .fontWeight(.semibold)
                .foregroundStyle(RN.Palette.rustText)
            }
            .font(.footnote)
            .nowStateLayer(visible: feed.loadMoreFailed && !feed.isLoadingMore)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
}

/// An entry card shape with stand-in text, redacted, so the feed's geometry is set before it loads.
private struct NowEntrySkeleton: View {
    let announces: Bool

    private static let entry = JournalEntry(
        id: "skeleton",
        profileId: "",
        entityId: "",
        entityKind: .song,
        document: .plain("A few lines about a song, long enough to fill the card the way a real observation does once it arrives, with room for a second thought."),
        plainText: "",
        lenses: [.feeling, .production],
        createdAt: "",
        updatedAt: ""
    )
    private static let author = Profile(id: "", handle: "listener", displayName: "Listener")
    private static let entity = CatalogEntity.song(Song(id: "", name: "Song title", slug: "", artistId: ""))

    var body: some View {
        EntryCard(entry: Self.entry, author: Self.author, entity: Self.entity)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading recent writing")
            .accessibilityHidden(!announces)
    }
}

/// A quiet row in place of the feed when its first page can't load.
private struct NowFeedErrorRow: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: RN.Space.m) {
            Text("Recent writing didn't load.")
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
            Spacer(minLength: 0)
            Button("Retry", action: retry)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(RN.Palette.rustText)
        }
        .padding(RN.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
