import ResonoteKit
import SwiftUI

/// One album inside an artist's group: liked itself, or holding liked songs.
struct LibraryAlbumGroup: Identifiable, Equatable {
    let album: Album
    let isLiked: Bool
    let songs: [Song]

    var id: String { album.id }
}

/// An artist and the liked music under them. Liking a song does not imply its
/// album or artist is liked; each level shows only what was liked there.
struct LibraryArtistGroup: Identifiable, Equatable {
    let artistId: String
    let artist: Artist?
    let isLiked: Bool
    let albums: [LibraryAlbumGroup]
    let looseSongs: [Song]
    let artworkURL: String?

    var id: String { artistId }
    var likedSongCount: Int { albums.reduce(0) { $0 + $1.songs.count } + looseSongs.count }
}

enum LibraryGrouping {
    struct Result: Equatable {
        var groups: [LibraryArtistGroup]
        /// Liked music this device has no catalog row for yet.
        var missing: [CatalogRef]
    }

    /// Mirrors the web's `getProfileLibrary`: artists → albums → songs.
    static func make(likes: [Like], catalog: CatalogIndex) -> Result {
        var likedArtists = Set<String>()
        var likedAlbums = Set<String>()
        var likedSongs: [String: Song] = [:]
        var missing: [CatalogRef] = []

        for like in likes {
            switch like.entityKind {
            case .artist:
                likedArtists.insert(like.entityId)
                if catalog.artists[like.entityId] == nil { missing.append(CatalogRef(kind: .artist, id: like.entityId)) }
            case .album:
                if catalog.albums[like.entityId] != nil {
                    likedAlbums.insert(like.entityId)
                } else {
                    missing.append(CatalogRef(kind: .album, id: like.entityId))
                }
            case .song:
                if let song = catalog.songs[like.entityId] {
                    likedSongs[song.id] = song
                } else {
                    missing.append(CatalogRef(kind: .song, id: like.entityId))
                }
            case .genre:
                break
            }
        }

        var albumIdsByArtist: [String: Set<String>] = [:]
        var songsByAlbum: [String: [Song]] = [:]
        var looseByArtist: [String: [Song]] = [:]
        var artistIds = likedArtists

        for id in likedAlbums {
            guard let album = catalog.albums[id] else { continue }
            albumIdsByArtist[album.artistId, default: []].insert(id)
            artistIds.insert(album.artistId)
        }
        for song in likedSongs.values {
            if let albumId = song.albumId, let album = catalog.albums[albumId] {
                songsByAlbum[albumId, default: []].append(song)
                albumIdsByArtist[album.artistId, default: []].insert(albumId)
                artistIds.insert(album.artistId)
            } else {
                looseByArtist[song.artistId, default: []].append(song)
                artistIds.insert(song.artistId)
            }
        }

        let groups = artistIds.map { artistId -> LibraryArtistGroup in
            let albums = (albumIdsByArtist[artistId] ?? [])
                .compactMap { catalog.albums[$0] }
                .sorted(by: albumOrder)
                .map { album in
                    LibraryAlbumGroup(album: album, isLiked: likedAlbums.contains(album.id), songs: (songsByAlbum[album.id] ?? []).sorted(by: songOrder))
                }
            let artist = catalog.artists[artistId]
            return LibraryArtistGroup(
                artistId: artistId,
                artist: artist,
                isLiked: likedArtists.contains(artistId),
                albums: albums,
                looseSongs: (looseByArtist[artistId] ?? []).sorted(by: songOrder),
                artworkURL: artist?.imageUrl ?? albums.lazy.compactMap(\.album.imageUrl).first
            )
        }
        .sorted { a, b in
            switch (a.artist, b.artist) {
            case let (left?, right?):
                return (left.sortName ?? left.name).localizedStandardCompare(right.sortName ?? right.name) == .orderedAscending
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.artistId < b.artistId
            }
        }
        return Result(groups: groups, missing: missing)
    }

    private static func albumOrder(_ a: Album, _ b: Album) -> Bool {
        if a.year != b.year { return (a.year ?? .max) < (b.year ?? .max) }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func songOrder(_ a: Song, _ b: Song) -> Bool {
        if a.trackNumber != b.trackNumber { return (a.trackNumber ?? .max) < (b.trackNumber ?? .max) }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// "Affirmative taste": liked music as artist groups that open to albums and songs.
/// Which artists are open is remembered per profile.
struct ProfileLibraryView: View {
    let bundle: ProfileBundle
    let isOwner: Bool
    let unavailable: Set<String>

    @Environment(AppModel.self) private var model
    @AppStorage private var openStorage: String
    /// The grouping, recomputed only when the likes or the catalog change, not on every
    /// render (opening an artist re-renders this view).
    @State private var memo = JournalMemo<LibraryInput, LibraryGrouping.Result>()

    private struct LibraryInput: Equatable {
        var likes: [Like]
        var catalogRevision: Int
    }

    init(bundle: ProfileBundle, isOwner: Bool, unavailable: Set<String>) {
        self.bundle = bundle
        self.isOwner = isOwner
        self.unavailable = unavailable
        _openStorage = AppStorage(wrappedValue: "", "library-open-\(bundle.profile.id)")
    }

    /// Each artist is its own child of the profile's lazy stack, so rows (and their
    /// artwork) are built only as they scroll into view.
    var body: some View {
        let catalog = model.catalog
        let library = memo.value(for: LibraryInput(likes: bundle.likes, catalogRevision: model.catalogRevision)) { input in
            LibraryGrouping.make(likes: input.likes, catalog: catalog)
        }
        let loading = library.missing.filter { !unavailable.contains($0.id) }
        if library.groups.isEmpty, loading.isEmpty {
            EmptyStateView(
                title: "No liked music yet",
                message: isOwner
                    ? "Tap the heart on any artist, album, or song and it collects here."
                    : "Music they like will collect here."
            )
        } else {
            ForEach(library.groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    DisclosureGroup(isExpanded: isOpen(group.id)) {
                        LibraryArtistContents(group: group)
                    } label: {
                        LibraryArtistLabel(group: group)
                    }
                    .disclosureGroupStyle(LibraryDisclosureStyle())
                    Rectangle().fill(RN.Palette.line).frame(height: 1)
                }
            }
            ForEach(loading.prefix(3), id: \.id) { _ in
                CatalogRowPlaceholder(artworkSize: 40)
                    .padding(.vertical, RN.Space.m)
            }
        }
    }

    private var openIds: Set<String> {
        Set(openStorage.split(separator: "\n").map(String.init))
    }

    private func isOpen(_ artistId: String) -> Binding<Bool> {
        Binding(
            get: { openIds.contains(artistId) },
            set: { open in
                var ids = openIds
                if open { ids.insert(artistId) } else { ids.remove(artistId) }
                openStorage = ids.sorted().joined(separator: "\n")
            }
        )
    }
}

private struct LibraryArtistLabel: View {
    let group: LibraryArtistGroup

    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: RN.Space.m) {
            ArtworkView(group.artworkURL, title: group.artist?.name ?? "", size: 40, cornerRadius: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.artist?.name ?? "Unknown artist")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(group.artist == nil ? RN.Palette.muted : RN.Palette.ink)
                    .lineLimit(1)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            if group.isLiked {
                Image(systemName: "heart.fill")
                    .font(.footnote)
                    .foregroundStyle(RN.Palette.rustText)
                    .accessibilityLabel("Liked artist")
            }
        }
        .contextMenu {
            if let artist = group.artist {
                Button("Open artist", systemImage: "person.crop.circle") {
                    router.push(.entity(kind: .artist, id: artist.id))
                }
            }
        }
        .accessibilityAction(named: "Open artist") {
            if let artist = group.artist { router.push(.entity(kind: .artist, id: artist.id)) }
        }
    }

    private var summary: String {
        let songs = group.likedSongCount
        if songs > 0 { return JournalCopy.count(songs, "liked song") }
        if !group.albums.isEmpty { return JournalCopy.count(group.albums.count, "liked album") }
        return "Liked artist"
    }
}

private struct LibraryArtistContents: View {
    let group: LibraryArtistGroup

    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            ForEach(group.albums) { albumGroup in
                VStack(alignment: .leading, spacing: RN.Space.s) {
                    Button {
                        router.push(.entity(kind: .album, id: albumGroup.album.id))
                    } label: {
                        HStack(spacing: RN.Space.m) {
                            ArtworkView(albumGroup.album.imageUrl, title: albumGroup.album.name, size: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(albumGroup.album.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(RN.Palette.ink)
                                    .lineLimit(2)
                                if let year = albumGroup.album.year {
                                    Text(String(year))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(RN.Palette.muted)
                                }
                            }
                            Spacer(minLength: 0)
                            if albumGroup.isLiked {
                                Label("Liked album", systemImage: "heart.fill")
                                    .font(.caption)
                                    .foregroundStyle(RN.Palette.rustText)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    songList(albumGroup.songs)
                        .padding(.leading, 52)
                }
            }
            songList(group.looseSongs)
        }
    }

    @ViewBuilder
    private func songList(_ songs: [Song]) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(songs) { song in
                    Button {
                        router.push(.entity(kind: .song, id: song.id))
                    } label: {
                        HStack(spacing: RN.Space.s) {
                            Text(song.name)
                                .font(.subheadline)
                                .foregroundStyle(RN.Palette.ink)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(RN.Palette.rustText)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(song.name), liked song")
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }
}

/// A full-width row that opens and closes, with a chevron that turns. The
/// motion is the person's own tap, so it plays unless Reduce Motion is on.
private struct LibraryDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        LibraryDisclosure(configuration: configuration)
    }
}

private struct LibraryDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : RN.Motion.settle) {
                    configuration.$isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: RN.Space.m) {
                    configuration.label
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RN.Palette.muted)
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, RN.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(configuration.isExpanded ? "Hides liked albums and songs" : "Shows liked albums and songs")
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, RN.Space.xl)
                    .padding(.bottom, RN.Space.l)
            }
        }
    }
}
