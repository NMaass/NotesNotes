import ResonoteKit
import SwiftUI

/// Avatar, name, handle, bio, genres, and the profile track.
struct ProfileHeader: View {
    let profile: Profile
    let unavailable: Set<String>

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            HStack(alignment: .center, spacing: RN.Space.l) {
                ProfileAvatar(name: profile.displayName, size: 74)
                VStack(alignment: .leading, spacing: RN.Space.xs) {
                    Text(profile.displayName)
                        .font(RN.Typography.display)
                        .foregroundStyle(RN.Palette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .accessibilityAddTraits(.isHeader)
                    Text("@\(profile.handle)")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !profile.bio.isEmpty {
                Text(profile.bio)
                    .font(.body)
                    .foregroundStyle(RN.Palette.prose)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !profile.genreIds.isEmpty {
                genres
            }
            if let songId = profile.profileSongId {
                ProfileTrackCard(songId: songId, isUnavailable: unavailable.contains(songId))
            }
        }
    }

    private var genres: some View {
        FlowLayout {
            ForEach(profile.genreIds, id: \.self) { id in
                if let genre = model.catalog.genres[id] {
                    Chip(genre.name) { router.push(.entity(kind: .genre, id: genre.id)) }
                        .accessibilityHint("Opens the genre")
                } else if !unavailable.contains(id) {
                    Chip("Genre name") {}
                        .redacted(reason: .placeholder)
                        .disabled(true)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// The initial on the web's rust-to-teal gradient.
struct ProfileAvatar: View {
    let name: String
    var size: CGFloat = 74

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hex: 0xC6543C), Color(hex: 0x315C65)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().strokeBorder(RN.Palette.lineStrong))
            .overlay {
                Text(initial)
                    .font(.custom("Georgia", fixedSize: size * 0.42))
                    .foregroundStyle(Color(hex: 0xFFF3E6))
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? ""
    }
}

/// The song someone chose to represent their profile.
private struct ProfileTrackCard: View {
    let songId: String
    let isUnavailable: Bool

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            if let song = model.catalog.songs[songId] {
                Button {
                    router.push(.entity(kind: .song, id: song.id))
                } label: {
                    card(song)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Profile track, \(song.name), \(model.catalog.subtitle(for: .song(song)))")
                .accessibilityAddTraits(.isButton)
            } else {
                CatalogRowPlaceholder(artworkSize: 64, isUnavailable: isUnavailable)
                    .padding(RN.Space.m)
                    .cardSurface()
            }
        }
    }

    private func card(_ song: Song) -> some View {
        HStack(spacing: RN.Space.m) {
            VinylView(artworkURL: model.catalog.artworkURL(for: .song(song)), title: song.name, isPlaying: false, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Label("Profile track", systemImage: "dot.radiowaves.left.and.right")
                    .font(RN.Typography.eyebrow)
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(RN.Palette.rustText)
                Text(song.name)
                    .font(RN.Typography.headline)
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text(model.catalog.subtitle(for: .song(song)))
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RN.Palette.muted)
        }
        .padding(RN.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: RN.Radius.card))
    }
}
