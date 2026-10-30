import ResonoteKit
import SwiftUI

/// The bar above the tab bar, like the mini player in Music: the current track and
/// a Write button, or a way to identify a song when nothing is known. Its contents
/// keep one line height in both placements so the bar never jumps.
struct NowPlayingAccessory: View {
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(Router.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isExpanded: Bool { placement != .inline }

    var body: some View {
        Group {
            if let track = nowPlaying.track {
                playing(track)
            } else {
                identify
            }
        }
        .padding(.horizontal, isExpanded ? 14 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func playing(_ track: NowPlayingTrack) -> some View {
        let artwork = nowPlaying.nowArtworkURL
        return HStack(spacing: 10) {
            Button {
                router.tab = .now
            } label: {
                HStack(spacing: 10) {
                    ArtworkView(artwork, title: track.title, size: 30, cornerRadius: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if isExpanded, !track.artist.isEmpty {
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityTitle(track))
            .accessibilityHint("Shows the Now tab")

            // The song shown may not be what's playing now (a paused or earlier song).
            Button {
                router.present(.identify)
            } label: {
                ListeningWaveform(isActive: nowPlaying.isIdentifying, height: 14)
                    .frame(width: 22, height: 22)
                    // Another app is audible and nothing vouches for this song.
                    .foregroundStyle(nowPlaying.suggestsIdentify ? RN.Palette.rustText : Color.primary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 36, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel(nowPlaying.isIdentifying ? "Listening" : "Identify a different song")
            .accessibilityHint("Listens for the song playing nearby")

            Button {
                router.present(.capture(CapturePreset(origin: "accessory")))
            } label: {
                if isExpanded {
                    Label("Write", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(RN.Palette.rustText)
            .frame(minWidth: 36, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel("Write about \(track.title)")
        }
    }

    private var identify: some View {
        Button {
            router.present(.identify)
        } label: {
            HStack(spacing: 10) {
                ListeningWaveform(isActive: nowPlaying.isIdentifying, height: 14)
                    .frame(width: 30, height: 30)
                Text(nowPlaying.isIdentifying ? "Listening…" : "Identify a song")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nowPlaying.isIdentifying ? "Listening" : "Identify a song")
        .accessibilityHint("Listens for the song playing nearby")
    }

    private func accessibilityTitle(_ track: NowPlayingTrack) -> String {
        let who = track.artist.isEmpty ? track.title : "\(track.title) by \(track.artist)"
        return nowPlaying.isConfirmedPlaying ? "Now playing, \(who)" : "Last heard, \(who)"
    }
}
