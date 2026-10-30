import ResonoteKit
import SwiftUI

#if canImport(JournalingSuggestions)
import JournalingSuggestions
#endif

// The capture sheet's "Recently played" row (docs/IOS_NOW_PLAYING.md → Using recent
// plays so nobody types): the attached song in one line, the next few recent songs as
// chips, and the Journaling Suggestions picker for plays only the system saw.

/// How a recent play is shown in a chip or a row.
enum CaptureRecentCopy {
    /// "2 min ago", "playing now", or the source for an undated play.
    static func when(_ play: RecentPlay, now: Date) -> String {
        if play.isPlaying { return "playing now" }
        guard let played = play.playedAt else { return play.source.label }
        return NowRelativeTime.phrase(since: played, now: now)
    }

    /// "Weird Fishes/Arpeggi · Radiohead · recently played · automatically attached", or
    /// for a note written first, "… · playing when you wrote this · attached automatically".
    static func attached(_ play: RecentPlay, writtenFirst: Bool = false) -> String {
        if writtenFirst {
            return ([play.title, play.artist].filter { !$0.isEmpty } + ["playing when you wrote this", "attached automatically"]).joined(separator: " · ")
        }
        let state = play.isPlaying ? "playing now" : "recently played"
        return ([play.title, play.artist].filter { !$0.isEmpty } + [state, "automatically attached"]).joined(separator: " · ")
    }
}

/// The line under the header while a song is on screen: which recent play is attached
/// and a few others to switch to in one tap.
struct CaptureRecentPlays: View {
    /// Ranked recent plays, newest first.
    let plays: [RecentPlay]
    /// The recent play the sheet's song is, if it is one.
    let attached: RecentPlay?
    /// The sheet chose `attached` itself (nobody tapped anything yet).
    let isAutomatic: Bool
    let onChoose: (RecentPlay) -> Void
    let onJournalingPick: @MainActor ([RecentPlay], URL?) -> Void
    /// The words were written first and the song attached afterwards.
    var isWrittenFirst = false
    /// Leaves a written-first note with no song; nil where a song is required.
    var onDetach: (() -> Void)?

    private static let chipLimit = 4

    var body: some View {
        let others = plays.filter { $0.id != attached?.id }.prefix(Self.chipLimit)
        VStack(alignment: .leading, spacing: RN.Space.s) {
            CaptureSectionTitle("Recently played")
            if let attached, isAutomatic {
                HStack(alignment: .firstTextBaseline, spacing: RN.Space.s) {
                    Text(CaptureRecentCopy.attached(attached, writtenFirst: isWrittenFirst))
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    changeMenu(others: Array(others))
                }
            } else if attached != nil, let onDetach {
                // Chosen by the person: still theirs to undo.
                Button("Remove song", systemImage: "minus.circle", action: onDetach)
                    .font(.footnote.weight(.medium))
                    .accessibilityHint("Keeps the note with no song")
            }
            ScrollView(.horizontal) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: RN.Space.s) {
                        ForEach(Array(others)) { play in
                            Chip("\(play.title) · \(CaptureRecentCopy.when(play, now: context.date))") { onChoose(play) }
                                .accessibilityLabel("\(play.title) by \(play.artist), \(CaptureRecentCopy.when(play, now: context.date))")
                                .accessibilityHint("Writes about this song instead")
                        }
                        CaptureJournalingButton(onPick: onJournalingPick)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    /// "Change": another recent play, or (written first) no song at all.
    private func changeMenu(others: [RecentPlay]) -> some View {
        Menu {
            ForEach(others) { play in
                Button("\(play.title) · \(play.artist)") { onChoose(play) }
            }
            if let onDetach {
                Divider()
                Button("No song yet", systemImage: "minus.circle", action: onDetach)
            }
        } label: {
            Text("Change")
                .font(.footnote.weight(.semibold))
        }
        .accessibilityHint("Picks a different song for this note")
    }
}

/// Nothing is attached: two or three recent songs with artwork to pick from, before
/// any search box.
struct CaptureRecentChoices: View {
    let plays: [RecentPlay]
    let icons: [String: URL]
    let onChoose: (RecentPlay) -> Void
    let onJournalingPick: @MainActor ([RecentPlay], URL?) -> Void

    private static let rowLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            CaptureSectionTitle(plays.isEmpty ? "Recently played" : "Was it one of these?")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: RN.Space.xs) {
                    ForEach(Array(plays.prefix(Self.rowLimit))) { play in
                        Button { onChoose(play) } label: {
                            CaptureRecentRow(play: play, icon: icons[play.matchKey], when: CaptureRecentCopy.when(play, now: context.date))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Writes about this song")
                    }
                }
            }
            CaptureJournalingButton(onPick: onJournalingPick)
        }
    }
}

/// One recent play with its artwork (or the playing app's icon).
struct CaptureRecentRow: View {
    let play: RecentPlay
    let icon: URL?
    let when: String

    var body: some View {
        HStack(spacing: RN.Space.m) {
            ArtworkView(play.artworkURL ?? icon?.absoluteString, title: play.title, size: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(play.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                Text([play.artist, when].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RN.Space.m)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// A weak match: two or three candidates with artwork, chosen with one tap.
struct CaptureCandidateRows: View {
    let candidates: [SearchResult]
    let isBusy: Bool
    let onChoose: (SearchResult) -> Void

    private static let rowLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            CaptureSectionTitle("Is it one of these?")
            ForEach(Array(candidates.prefix(Self.rowLimit))) { candidate in
                Button { onChoose(candidate) } label: {
                    HStack(spacing: RN.Space.m) {
                        ArtworkView(candidate.entity.imageUrl, title: candidate.entity.name, size: 44, cornerRadius: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.entity.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(RN.Palette.ink)
                                .lineLimit(1)
                            Text(candidate.subtitle)
                                .font(.caption)
                                .foregroundStyle(RN.Palette.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, RN.Space.m)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                    .cardSurface()
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityHint("Matches what you heard to this song")
            }
        }
    }
}

/// "Something else is playing": shown above the form when another app is audible, the
/// Music app is silent, and no source vouches for the song on screen.
struct CaptureIdentifyPrompt: View {
    let isListening: Bool
    let onIdentify: () -> Void

    var body: some View {
        HStack(spacing: RN.Space.m) {
            Text("Something's playing that Resonote can't see.")
                .font(.subheadline)
                .foregroundStyle(RN.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onIdentify) {
                Label("Identify", systemImage: "waveform")
            }
            .buttonStyle(.solid)
            .disabled(isListening)
            .accessibilityHint("Listens for the song playing nearby")
        }
        .padding(RN.Space.m)
        .cardSurface()
    }
}

// MARK: - Journaling Suggestions

/// Opens the system's Journaling Suggestions sheet. It lists what every app that
/// publishes Now Playing played (Spotify, YouTube Music, podcasts) next to photos and
/// workouts; Resonote receives only the item the person picks. iOS only: the framework
/// isn't in the Mac Catalyst SDK the typecheck uses, so this compiles there to nothing.
struct CaptureJournalingButton: View {
    let onPick: @MainActor ([RecentPlay], URL?) -> Void

    var body: some View {
        #if canImport(JournalingSuggestions)
        JournalingSuggestionsPicker {
            Label("Journal suggestions", systemImage: "book.pages")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .overlay(Capsule().strokeBorder(RN.Palette.line))
        } onCompletion: { suggestion in
            let picked = await JournalingPlays.plays(in: suggestion)
            await onPick(picked.plays, picked.icon)
        }
        .accessibilityHint("Picks a song from what your iPhone played recently, in any app")
        #else
        EmptyView()
        #endif
    }
}

#if canImport(JournalingSuggestions)
/// Songs in a picked suggestion: `GenericMedia` (iOS 18; any app's Now Playing, with the
/// app's icon) and `Song` (iOS 17.2; Music library songs).
enum JournalingPlays {
    static func plays(in suggestion: JournalingSuggestion) async -> (plays: [RecentPlay], icon: URL?) {
        let fallbackDate = suggestion.date?.start
        var plays: [RecentPlay] = []
        var icon: URL?
        for media in await suggestion.content(forType: JournalingSuggestion.GenericMedia.self) {
            guard let title = clean(media.title) else { continue }
            icon = icon ?? media.appIcon
            plays.append(RecentPlay(title: title, artist: clean(media.artist) ?? "", album: clean(media.album), playedAt: media.date ?? fallbackDate, source: .journalingSuggestion))
        }
        for song in await suggestion.content(forType: JournalingSuggestion.Song.self) {
            guard let title = clean(song.song) else { continue }
            plays.append(RecentPlay(title: title, artist: clean(song.artist) ?? "", album: clean(song.album), playedAt: song.date ?? fallbackDate, source: .journalingSuggestion, artworkURL: webURL(song.artwork)))
        }
        return (plays, icon)
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The picker hands over local files; only web artwork may go to the resolver.
    private static func webURL(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url.absoluteString
    }
}
#endif

/// Nothing Resonote can see is playing: write now, and the song you were playing
/// attaches itself once a source reports it (write first, attach later).
struct CaptureWriteFirstButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: RN.Space.m) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(RN.Palette.rust)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write first, add the song later")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RN.Palette.ink)
                    Text("It keeps the time, and the song you were playing attaches when a source reports it.")
                        .font(.caption)
                        .foregroundStyle(RN.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RN.Space.m)
            .padding(.vertical, RN.Space.s)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .cardSurface()
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the note field without a song")
    }
}
