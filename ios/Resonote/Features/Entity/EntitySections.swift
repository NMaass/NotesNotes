import ResonoteKit
import SwiftUI

// MARK: Genre tags

/// One genre on an entity, with the signed-in person's own unsynced tags folded in.
struct EntityGenreChip: Identifiable, Hashable {
    let id: String
    let name: String
    let votes: Int
    let mine: Bool

    /// Server totals, adjusted for tags this person added or removed on this device since
    /// the page loaded. Server order is kept so chips never reorder under a finger.
    static func items(for page: EntityPage, model: AppModel, directory: [String: Genre]) -> [EntityGenreChip] {
        let viewer = model.profile?.id
        let localMine = Set((model.bundle?.genreAssertions ?? []).filter { $0.entityId == page.entity.id }.map(\.genreId))
        // The `mine` flags are only comparable when the page loaded for this same person.
        let comparable = viewer != nil && viewer == page.viewer
        var items: [EntityGenreChip] = []
        var seen = Set<String>()
        for tag in page.genres {
            seen.insert(tag.genre.id)
            var votes = tag.votes
            var mine = tag.mine ?? false
            if comparable {
                let nowMine = localMine.contains(tag.genre.id)
                votes += (nowMine ? 1 : 0) - (mine ? 1 : 0)
                mine = nowMine
            }
            guard votes > 0 else { continue }
            items.append(EntityGenreChip(id: tag.genre.id, name: tag.genre.name, votes: votes, mine: mine))
        }
        guard comparable else { return items }
        for genreId in localMine.sorted() where !seen.contains(genreId) {
            guard let name = model.catalog.genres[genreId]?.name ?? directory[genreId]?.name else { continue }
            items.append(EntityGenreChip(id: genreId, name: name, votes: 1, mine: true))
        }
        return items
    }
}

/// Genre links under the header. Counts show only when more than one person agrees.
struct EntityGenreChipRow: View {
    let items: [EntityGenreChip]

    var body: some View {
        FlowLayout {
            ForEach(items) { item in
                NavigationLink(value: Route.entity(kind: .genre, id: item.id)) {
                    HStack(spacing: 6) {
                        Text(item.name)
                        if item.votes > 1 {
                            Text(String(item.votes))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(RN.Palette.muted)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .background(RN.Palette.fill, in: Capsule())
                    .overlay(Capsule().strokeBorder(item.mine ? RN.Palette.lineStrong : RN.Palette.line))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.votes > 1 ? "\(item.name), \(item.votes) tags" : item.name)
                .accessibilityHint("Opens the genre")
            }
        }
    }
}

// MARK: Album tracklist

struct EntityTracklistSection: View {
    let tracks: [EntityPage.Track]
    let onWriteNow: (Song) -> Void

    @Environment(AppModel.self) private var model
    @State private var likeTaps = 0

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            SectionHeader(eyebrow: "Tracklist", title: "Listen one track at a time")
            VStack(spacing: 0) {
                ForEach(tracks) { track in
                    if track.id != tracks.first?.id {
                        Divider().overlay(RN.Palette.line)
                    }
                    row(track)
                }
            }
            .padding(.horizontal, RN.Space.m)
            .cardSurface()
            .sensoryFeedback(.impact(weight: .light), trigger: likeTaps)
        }
    }

    private func row(_ track: EntityPage.Track) -> some View {
        let liked = model.isLiked(track.song.id)
        return HStack(spacing: RN.Space.s) {
            NavigationLink(value: Route.entity(kind: .song, id: track.song.id)) {
                HStack(spacing: RN.Space.m) {
                    Text(track.number)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(RN.Palette.muted)
                        .frame(minWidth: 22, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.song.name)
                            .font(.body)
                            .foregroundStyle(RN.Palette.ink)
                            .lineLimit(2)
                        if track.song.isBonusTrack == true {
                            Text("bonus track")
                                .font(.caption)
                                .foregroundStyle(RN.Palette.muted)
                        }
                    }
                    Spacer(minLength: RN.Space.s)
                    if let duration = track.duration {
                        Text(duration)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(RN.Palette.muted)
                    }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Write about this now", systemImage: "record.circle") { onWriteNow(track.song) }
            }

            Button {
                likeTaps += 1
                model.toggleLike(.song(track.song))
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? RN.Palette.rust : RN.Palette.muted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(liked ? "Unlike \(track.song.name)" : "Like \(track.song.name)")
            .accessibilityAddTraits(liked ? .isSelected : [])
        }
    }
}

// MARK: Albums and songs

/// Two columns of covers, each tile the same height whatever its title length.
struct EntityAlbumGrid: View {
    let eyebrow: String
    let title: String
    let albums: [Album]

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            SectionHeader(eyebrow: eyebrow, title: title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: RN.Space.l), GridItem(.flexible(), spacing: RN.Space.l)], alignment: .leading, spacing: RN.Space.l) {
                ForEach(albums) { album in
                    NavigationLink(value: Route.entity(kind: .album, id: album.id)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    GeometryReader { proxy in
                                        ArtworkView(album.imageUrl, title: album.name, size: proxy.size.width, cornerRadius: RN.Radius.button)
                                    }
                                }
                            Text(album.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(RN.Palette.ink)
                                .lineLimit(2, reservesSpace: true)
                                .multilineTextAlignment(.leading)
                            Text(album.year.map(String.init) ?? " ")
                                .font(.caption)
                                .foregroundStyle(RN.Palette.muted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// Song rows; long lists open in full only when asked.
struct EntitySongList: View {
    let eyebrow: String
    let title: String
    let songs: [EntityPage.SongLine]
    let onWriteNow: (Song) -> Void

    @State private var showsAll = false
    private let collapsedCount = 8

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            SectionHeader(eyebrow: eyebrow, title: title)
            VStack(spacing: 0) {
                ForEach(showsAll ? songs : Array(songs.prefix(collapsedCount))) { line in
                    if line.id != songs.first?.id {
                        Divider().overlay(RN.Palette.line)
                    }
                    NavigationLink(value: Route.entity(kind: .song, id: line.song.id)) {
                        EntityRow(entity: .song(line.song), subtitle: line.subtitle, artworkURL: line.artworkURL, trailing: EntityPage.duration(line.song.durationMs) ?? "")
                            .padding(.vertical, RN.Space.s)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Write about this now", systemImage: "record.circle") { onWriteNow(line.song) }
                    }
                }
            }
            .padding(.horizontal, RN.Space.m)
            .cardSurface()
            if songs.count > collapsedCount {
                Button {
                    showsAll.toggle()
                } label: {
                    StableLabel(showsAll ? "Show fewer" : "Show all \(songs.count)", among: ["Show fewer", "Show all \(songs.count)"])
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.outline)
            }
        }
    }
}

// MARK: Genre pages

struct EntityGenreIntro: View {
    let description: String?
    let taggedSummary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            if let description, !description.isEmpty {
                Text(description)
                    .font(RN.Typography.prose)
                    .lineSpacing(5)
                    .foregroundStyle(RN.Palette.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let taggedSummary {
                VStack(alignment: .leading, spacing: RN.Space.xs) {
                    Text(taggedSummary)
                        .font(RN.Typography.headline)
                        .foregroundStyle(RN.Palette.ink)
                    Text("Open any album or song below and press Tag genre to add yours. Catalog and community tags keep their sources.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(RN.Space.l)
                .cardSurface()
            }
        }
    }
}

// MARK: Song credits and structure

enum EntitySongInfo: String, Identifiable {
    case credits, facts
    var id: String { rawValue }
}

struct EntitySongInfoRows: View {
    let credits: Int
    let facts: Int
    let open: (EntitySongInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            row("Credits", systemImage: "person.2", detail: credits == 0 ? "None cached yet" : credits == 1 ? "1 collaborator" : "\(credits) collaborators") { open(.credits) }
            Divider().overlay(RN.Palette.line)
            row("Structure", systemImage: "waveform", detail: facts == 0 ? "None cached yet" : facts == 1 ? "1 fact" : "\(facts) facts") { open(.facts) }
        }
        .padding(.horizontal, RN.Space.m)
        .cardSurface()
    }

    private func row(_ title: String, systemImage: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: RN.Space.m) {
                Image(systemName: systemImage)
                    .foregroundStyle(RN.Palette.muted)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(RN.Palette.ink)
                Spacer(minLength: RN.Space.s)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.muted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Connections

struct EntityConnections: View {
    let connections: [EntityPage.ConnectionLine]

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            SectionHeader(eyebrow: "Human-made links", title: "Connections people heard")
            VStack(spacing: 0) {
                ForEach(connections) { connection in
                    if connection.id != connections.first?.id {
                        Divider().overlay(RN.Palette.line)
                    }
                    NavigationLink(value: Route.entity(kind: connection.entity.kind, id: connection.entity.id)) {
                        row(connection)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RN.Space.m)
            .cardSurface()
        }
    }

    private func row(_ connection: EntityPage.ConnectionLine) -> some View {
        HStack(alignment: .top, spacing: RN.Space.m) {
            ArtworkView(connection.artworkURL, title: connection.entity.name, size: 46, cornerRadius: connection.entity.kind == .artist ? 23 : RN.Radius.artwork)
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.entity.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text(connection.relations)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                if connection.lenses.isEmpty {
                    Text("uncategorized connection")
                        .font(.caption)
                        .foregroundStyle(RN.Palette.muted)
                } else {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(connection.lenses, id: \.self) { lens in
                            Text(lens)
                                .font(.caption)
                                .foregroundStyle(RN.Palette.muted)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .overlay(Capsule().strokeBorder(RN.Palette.line))
                        }
                    }
                }
            }
            Spacer(minLength: RN.Space.s)
            Text(connection.mentions)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(RN.Palette.muted)
        }
        .padding(.vertical, RN.Space.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: Journal

struct EntityOwnEntries: View {
    let entries: [JournalEntry]

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            SectionHeader(eyebrow: "Your journal", title: "Your entries")
            LazyVStack(spacing: RN.Space.m) {
                ForEach(entries) { entry in
                    EntryCard(entry: entry, author: model.profile) { router.push(.entry(id: entry.id)) }
                }
            }
        }
    }
}

struct EntityPublicEntries: View {
    let entries: [JournalEntry]
    let authors: [String: Profile]
    let write: () -> Void

    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            HStack(alignment: .lastTextBaseline) {
                SectionHeader(eyebrow: "Public journal", title: "What people noticed")
                if !entries.isEmpty {
                    Button("Write yours", action: write)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RN.Palette.rustText)
                }
            }
            if entries.isEmpty {
                EmptyStateView(
                    title: "No public thoughts yet",
                    message: "This page is ready for someone to notice something specific.",
                    actionTitle: "Write yours",
                    action: write
                )
            } else {
                LazyVStack(spacing: RN.Space.m) {
                    ForEach(entries) { entry in
                        EntryCard(entry: entry, author: authors[entry.profileId]) { router.push(.entry(id: entry.id)) }
                    }
                }
            }
        }
    }
}

// MARK: Loading

/// Rows the size of the sections that will replace them.
struct EntitySectionsPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            HStack(spacing: RN.Space.s) {
                ForEach([72.0, 96.0, 64.0], id: \.self) { width in
                    Capsule().fill(RN.Palette.fill).frame(width: width, height: 34)
                }
            }
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: RN.Radius.card)
                    .fill(RN.Palette.paper2)
                    .frame(height: 72)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// The header's shape before anything is known about the entity.
struct EntityHeaderPlaceholder: View {
    let kind: EntityKind

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            Group {
                switch kind {
                case .song, .album:
                    VinylView(artworkURL: nil, title: "", isPlaying: false, size: EntityHeader.artworkSize)
                case .artist:
                    Circle().fill(RN.Palette.paper2).frame(width: 152, height: 152)
                        .frame(height: EntityHeader.artworkSize)
                case .genre:
                    RoundedRectangle(cornerRadius: RN.Radius.card).fill(RN.Palette.paper2)
                        .frame(width: EntityHeader.artworkSize, height: EntityHeader.artworkSize)
                }
            }
            VStack(alignment: .leading, spacing: RN.Space.xs) {
                Eyebrow(kind.label)
                Text("Loading this page")
                    .font(RN.Typography.display)
                    .redacted(reason: .placeholder)
                if kind != .genre {
                    Text("Artist · Album")
                        .font(.subheadline)
                        .redacted(reason: .placeholder)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Checking the shelf…")
    }
}
