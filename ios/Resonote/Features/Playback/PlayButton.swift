import ResonoteKit
import SwiftUI

/// "Play" beside a one-line message, for a song's page. The row keeps its height whether
/// or not a message shows; playback starts only from this tap (`PlaybackService`).
struct PlayRow: View {
    let target: PlaybackTarget?

    @Environment(NowPlayingService.self) private var nowPlaying
    @State private var taps = 0

    var body: some View {
        let playback = nowPlaying.playback
        let working = playback.isWorking(on: target)
        let message = playback.message(for: target)
        HStack(alignment: .center, spacing: RN.Space.m) {
            Button {
                guard let target else { return }
                taps += 1
                playback.play(target)
            } label: {
                Label {
                    StableLabel(working ? "Starting…" : "Play", among: ["Play", "Starting…"])
                } icon: {
                    Image(systemName: "play.fill")
                }
                .padding(.horizontal, RN.Space.s)
                .frame(minHeight: 40)
            }
            .buttonStyle(.outline)
            .fixedSize()
            .disabled(target == nil || working)
            .accessibilityLabel(target.map { "Play \($0.title)" } ?? "Play")
            .accessibilityHint("Plays it on Spotify or Apple Music, or opens it in another app")
            .sensoryFeedback(.impact(weight: .light), trigger: taps)

            Text(message ?? " ")
                .font(.footnote)
                .foregroundStyle(RN.Palette.rustText)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(message == nil ? 0 : 1)
                .accessibilityHidden(message == nil)
        }
        .onChange(of: message) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}

/// An icon-only Play for tight places (the now-playing card, the capture sheet). Its
/// messages show in the host's status line: `PlaybackService.message(for:)`.
struct PlayIconButton: View {
    let target: PlaybackTarget?
    var size: CGFloat = 40

    @Environment(NowPlayingService.self) private var nowPlaying
    @State private var taps = 0

    var body: some View {
        let playback = nowPlaying.playback
        let working = playback.isWorking(on: target)
        let message = playback.message(for: target)
        Button {
            guard let target else { return }
            taps += 1
            playback.play(target)
        } label: {
            ZStack {
                Image(systemName: "play.fill")
                    .font(.body.weight(.semibold))
                    .opacity(working ? 0 : 1)
                ProgressView()
                    .controlSize(.small)
                    .opacity(working ? 1 : 0)
            }
            .foregroundStyle(RN.Palette.ink)
            .frame(width: size, height: size)
            .background(RN.Palette.fill, in: Circle())
            .overlay(Circle().strokeBorder(RN.Palette.line))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil || working)
        .opacity(target == nil ? 0.4 : 1)
        .accessibilityLabel(target.map { "Play \($0.title)" } ?? "Play")
        .accessibilityHint("Plays it on Spotify or Apple Music, or opens it in another app")
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .onChange(of: message) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }
}
