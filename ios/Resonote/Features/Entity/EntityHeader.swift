import ResonoteKit
import SwiftUI

/// Artwork, kind, name, byline, and summary. Everything here is known from the local
/// catalog, so it renders at once and does not move when the full page arrives.
struct EntityHeader: View {
    let page: EntityPage
    let isPlaying: Bool

    static let artworkSize: CGFloat = 176

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            artwork
            VStack(alignment: .leading, spacing: RN.Space.xs) {
                Eyebrow(page.kind.label)
                Text(page.name)
                    .font(RN.Typography.display)
                    .foregroundStyle(RN.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if page.kind != .genre {
                    EntityByline(page: page)
                }
            }
            if let summary = page.summary {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(RN.Palette.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var artwork: some View {
        switch page.kind {
        case .song, .album:
            VinylView(artworkURL: page.artworkURL, title: page.name, isPlaying: isPlaying, size: Self.artworkSize)
        case .artist:
            ArtworkView(page.artworkURL, title: page.name, size: 152, cornerRadius: 76)
                .frame(height: Self.artworkSize, alignment: .center)
        case .genre:
            GenreMosaic(covers: page.mosaic, title: page.name, size: Self.artworkSize)
        }
    }
}

/// "Artist · Album · 3:12" with the artist and album opening their pages. Always one
/// line tall, so learning the artist's name later doesn't push the page down.
private struct EntityByline: View {
    let page: EntityPage

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(" ").hidden().accessibilityHidden(true)
            parts
        }
        .font(.subheadline)
        .foregroundStyle(RN.Palette.muted)
    }

    private var artist: Artist? {
        page.artist.flatMap { $0.id == page.entity.id ? nil : $0 }
    }

    private var year: String? {
        if case .album(let album) = page.entity, let year = album.year { return String(year) }
        return nil
    }

    private var parts: some View {
        FlowLayout(spacing: 6, lineSpacing: 2) {
            if let artist {
                NavigationLink(value: Route.entity(kind: .artist, id: artist.id)) {
                    Text(artist.name).foregroundStyle(RN.Palette.ink)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the artist")
            }
            if let album = page.album {
                if artist != nil { separator }
                NavigationLink(value: Route.entity(kind: .album, id: album.id)) {
                    Text(album.name).foregroundStyle(RN.Palette.ink)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the album")
            }
            if let year {
                if artist != nil { separator }
                Text(year)
            }
            if let duration = page.duration {
                if artist != nil || page.album != nil { separator }
                Text(duration).monospacedDigit()
            }
        }
    }

    private var separator: some View {
        Text("·").accessibilityHidden(true)
    }
}

/// Four covers of music tagged with a genre, in the frame a single cover would take.
private struct GenreMosaic: View {
    let covers: [String]
    let title: String
    let size: CGFloat

    var body: some View {
        if covers.isEmpty {
            ArtworkView(nil, title: title, size: size, cornerRadius: RN.Radius.card)
        } else {
            let cell = (size - 2) / 2
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    tile(0, cell)
                    tile(1, cell)
                }
                GridRow {
                    tile(2, cell)
                    tile(3, cell)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: RN.Radius.card))
            .accessibilityElement()
            .accessibilityLabel("Album art associated with \(title)")
        }
    }

    private func tile(_ index: Int, _ cell: CGFloat) -> some View {
        ArtworkView(index < covers.count ? covers[index] : nil, title: title, size: cell, cornerRadius: 0)
    }
}

/// Like and Write, then the smaller actions in equal tiles. Every control keeps its
/// size whatever its state, so tapping one changes only that control.
struct EntityActions: View {
    let page: EntityPage

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Bumped by the person's own taps, so haptics never fire for a like or pin that arrived with data.
    @State private var likeTaps = 0
    @State private var pinTaps = 0

    private var entity: CatalogEntity { page.entity }

    var body: some View {
        let liked = model.isLiked(entity.id)
        let pinned = model.isPinned(.entity, entity.id)
        VStack(spacing: RN.Space.s) {
            HStack(spacing: RN.Space.s) {
                Button {
                    likeTaps += 1
                    model.toggleLike(entity)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? RN.Palette.rust : RN.Palette.ink)
                        StableLabel(liked ? "Liked" : "Like", among: ["Like", "Liked"])
                            .foregroundStyle(liked ? RN.Palette.rustText : RN.Palette.ink)
                    }
                    // The same height as the solid Write button beside it.
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.outline)
                .accessibilityLabel("Like")
                .accessibilityAddTraits(liked ? .isSelected : [])
                .sensoryFeedback(.impact(weight: .light), trigger: likeTaps)

                Button {
                    router.present(.compose(ComposerContext(entityKind: entity.kind, entityId: entity.id)))
                } label: {
                    Label("Write", systemImage: "square.and.pencil")
                }
                .buttonStyle(.solid)
            }

            LazyVGrid(columns: columns, spacing: RN.Space.s) {
                if case .song = entity {
                    Button {
                        model.requireAuth { router.present(.logListen(songId: entity.id)) }
                    } label: {
                        ActionTile(systemImage: "headphones") { Text("Log listen") }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    model.requireAuth { router.present(.collect(kind: entity.kind, id: entity.id)) }
                } label: {
                    ActionTile(systemImage: "folder.badge.plus") { Text("Collect") }
                }
                .buttonStyle(.plain)
                if entity.kind != .genre {
                    Button {
                        model.requireAuth { router.present(.tagGenre(kind: entity.kind, id: entity.id)) }
                    } label: {
                        ActionTile(systemImage: "tag") { Text("Tag genre") }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    pinTaps += 1
                    model.togglePin(.entity, entity.id)
                } label: {
                    ActionTile(systemImage: pinned ? "pin.fill" : "pin") {
                        StableLabel(pinned ? "Pinned" : "Pin", among: ["Pin", "Pinned"])
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pin to your profile")
                .accessibilityAddTraits(pinned ? .isSelected : [])
                .sensoryFeedback(.selection, trigger: pinTaps)
                if entity.kind != .genre {
                    openInMenu
                }
            }
        }
    }

    private var tileCount: Int {
        switch entity.kind {
        case .song: 5
        case .album, .artist: 4
        case .genre: 2
        }
    }

    /// Five or four tiles fit only at the smaller text sizes; from xLarge up the labels
    /// need the width of three columns, and accessibility sizes two.
    private var columns: [GridItem] {
        let count: Int
        if typeSize.isAccessibilitySize {
            count = 2
        } else if typeSize >= .xLarge {
            count = min(3, tileCount)
        } else {
            count = tileCount
        }
        return Array(repeating: GridItem(.flexible(), spacing: RN.Space.s), count: count)
    }

    private var openInMenu: some View {
        let term = EntityOpenInLinks.searchTerm(for: entity, artist: page.artist)
        return Menu {
            if let url = EntityOpenInLinks.appleMusic(term: term) {
                Button("Apple Music") { openURL(url) }
            }
            if let url = EntityOpenInLinks.spotify(for: entity, term: term) {
                Button("Spotify") { openURL(url) }
            }
            if let url = EntityOpenInLinks.youTubeMusic(for: entity, term: term) {
                Button("YouTube Music") { openURL(url) }
            }
        } label: {
            ActionTile(systemImage: "arrow.up.forward.app") { Text("Open in…") }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open in another app")
    }
}

/// An icon over a short label, in an equal-width cell drawn with the chip tokens.
private struct ActionTile<Caption: View>: View {
    let systemImage: String
    @ViewBuilder let caption: Caption

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Large text gets two lines, reserved in every tile so a row stays one height.
    private var labelLines: Int { typeSize >= .xLarge ? 2 : 1 }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.body)
                .frame(height: 22)
            caption
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(labelLines, reservesSpace: true)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(RN.Palette.ink)
        .padding(.horizontal, RN.Space.xs)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(RN.Palette.fill, in: RoundedRectangle(cornerRadius: RN.Radius.button))
        .overlay(RoundedRectangle(cornerRadius: RN.Radius.button).strokeBorder(RN.Palette.line))
        .contentShape(RoundedRectangle(cornerRadius: RN.Radius.button))
    }
}
