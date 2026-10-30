import ResonoteKit
import SwiftUI

// Pieces shared by the Now tab, the now-playing accessory, and the capture sheet.

// MARK: - Words

/// Short elapsed-time phrases: "just now", "4 min ago", "2 hr ago", "yesterday".
enum NowRelativeTime {
    static func phrase(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3_600)) hr ago"
        case ..<172_800: return "yesterday"
        case ..<604_800: return "\(Int(seconds / 86_400)) days ago"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

extension NowPlayingTrack {
    /// "Artist · Album", or whichever of the two is known.
    var nowByline: String {
        [artist, album ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Whether the source line changes as time passes (elapsed time, or a playback claim running out).
    var nowSourceIsTimed: Bool {
        isPlaying || source == .spotify || source == .lastfm || source == .listenbrainz
    }

    /// Where Resonote learned about this track, claiming playback only while the source
    /// vouches for it (`claimsPlayback`, the rule the widget uses too).
    func nowSourceLine(at now: Date) -> String {
        let playing = claimsPlayback(at: now)
        switch source {
        case .appleMusic:
            if playing { return "Apple Music · playing" }
            return isPlaying ? "Apple Music" : "Apple Music · paused"
        case .spotify, .lastfm, .listenbrainz:
            if playing { return "\(source.label) · playing" }
            guard let observed = observedDate else { return "\(source.label) · last played" }
            return "\(source.label) · last played \(NowRelativeTime.phrase(since: observed, now: now))"
        case .shazam, .link, .manual:
            return source.label
        }
    }
}

extension ResolveResponse {
    /// The best cover for a resolved track: the track's own, else the album's, else the song's.
    func nowArtworkURL(for track: NowPlayingTrack?) -> String? {
        track?.artworkURL ?? album?.imageUrl ?? song?.imageUrl
    }
}

extension NowPlayingService {
    /// Cover art for the current track, falling back to the matched album.
    var nowArtworkURL: String? {
        resolution?.nowArtworkURL(for: track) ?? track?.artworkURL
    }

    /// "Artist · Album": from the catalog once matched (it fills in as the catalog learns
    /// the artist), else as the source reported it.
    func byline(catalog: CatalogIndex) -> String? {
        if let song {
            let known = catalog.subtitle(for: .song(song))
            if !known.isEmpty { return known }
        }
        return track?.nowByline
    }
}

/// How far matching a track to the catalog has come, as one quiet line.
enum NowMatchStatus: Equatable {
    case matching
    case matched(publicThoughts: Int)
    case unmatched
    case signInToMatch
    case couldNotMatch

    /// - Parameter isSignedIn: whether the session can match tracks now (signed in, not expired).
    /// - Parameter isRestoring: the cached session is still being read at launch; say nothing yet.
    init?(phase: NowPlayingService.Phase, resolution: ResolveResponse?, isSignedIn: Bool, isRestoring: Bool = false) {
        guard !isRestoring else { return nil }
        switch phase {
        case .resolving:
            self = .matching
        case .ready:
            self = .matched(publicThoughts: resolution?.entriesCount ?? 0)
        case .unmatched:
            if !isSignedIn {
                self = .signInToMatch
            } else if resolution == nil {
                self = .couldNotMatch
            } else {
                self = .unmatched
            }
        case .idle, .looking, .nothing:
            return nil
        }
    }

    var text: String {
        switch self {
        case .matching: "Matching…"
        case .matched(0): "On Resonote"
        case .matched(1): "On Resonote · 1 published thought"
        case .matched(let count): "On Resonote · \(count) published thoughts"
        case .unmatched: "No exact match yet"
        case .signInToMatch: "Sign in to find this on Resonote"
        case .couldNotMatch: "Couldn't reach Resonote to match this"
        }
    }
}

// MARK: - Views

/// The source line ("Last.fm · last played 4 min ago"), redrawn while it can change with time.
struct NowSourceText: View {
    let track: NowPlayingTrack

    var body: some View {
        if track.nowSourceIsTimed {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(track.nowSourceLine(at: context.date))
            }
        } else {
            Text(track.nowSourceLine(at: .now))
        }
    }
}

/// A title, a subtitle, and a source line in a block whose height is declared up
/// front (two title lines and two small lines), so swapping tracks or states never
/// moves what sits below it.
struct NowTitleBlock<Source: View>: View {
    let title: String
    let subtitle: String?
    var titleLines = 2
    @ViewBuilder var source: Source

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(repeating: "Reserved\n", count: max(1, titleLines - 1)) + "Reserved")
                    .font(RN.Typography.headline)
                Text("Reserved").font(.subheadline)
                Text("Reserved").font(.caption)
            }
            .hidden()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RN.Typography.headline)
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(titleLines)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                        .lineLimit(1)
                }
                source
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One reserved status line ("Matching…", "On Resonote · 3 published thoughts"). Its
/// height is held even when empty, so a status arriving never pushes controls down.
/// A weak match offers its candidates from a menu in the action slot, so they never
/// push the note field or the feed around.
struct NowStatusLine: View {
    let text: String?
    var lines = 1
    var showsWaveform = false
    var actionTitle: String?
    var action: (() -> Void)?
    var candidates: [SearchResult]?
    var isChoosing = false
    var onChoose: ((SearchResult) -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: RN.Space.s) {
            if showsWaveform {
                ListeningWaveform(isActive: true, height: 12)
            }
            Text(text ?? " ")
                .lineLimit(lines, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(text == nil)
            if text != nil, let candidates, !candidates.isEmpty, let onChoose {
                NowCandidateMenu(candidates: candidates, isBusy: isChoosing, onChoose: onChoose)
            } else if let actionTitle, let action, text != nil {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RN.Palette.rustText)
            }
        }
        .font(.footnote)
        .foregroundStyle(RN.Palette.muted)
    }
}

/// "Is it one of these?" — up to five MusicBrainz candidates for a weak match, in a menu.
struct NowCandidateMenu: View {
    let candidates: [SearchResult]
    let isBusy: Bool
    let onChoose: (SearchResult) -> Void

    var body: some View {
        Menu {
            Section("Is it one of these?") {
                ForEach(Array(candidates.prefix(5).enumerated()), id: \.offset) { _, candidate in
                    Button {
                        onChoose(candidate)
                    } label: {
                        Text(candidate.entity.name)
                        Text(candidate.subtitle)
                    }
                }
            }
        } label: {
            Text("Choose a match")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RN.Palette.rustText)
        }
        .disabled(isBusy)
        .accessibilityHint("Matches what you're hearing to one of a few songs")
    }
}

/// A calm, slow waveform: it moves only while Resonote is actually listening, and
/// holds still under Reduce Motion.
struct ListeningWaveform: View {
    var isActive: Bool
    var height: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let resting: [CGFloat] = [0.45, 0.75, 1.0, 0.7, 0.5]
    private var animates: Bool { isActive && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: height * 0.16) {
                ForEach(Self.resting.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: max(2, height * 0.18), height: barHeight(index, time: time))
                }
            }
        }
        .frame(width: height * 1.6, height: height)
        .foregroundStyle(RN.Palette.rustText)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int, time: TimeInterval) -> CGFloat {
        guard animates else { return height * Self.resting[index] }
        let wave = sin(time * 2.2 + Double(index) * 0.9)
        return height * (0.3 + 0.7 * CGFloat((wave + 1) / 2))
    }
}

/// PasteButton's handler, built off the main actor so it is safe whichever thread
/// the system calls it on, then hopping to the main actor with the first URL.
enum NowPaste {
    nonisolated static func handler(_ use: @escaping @MainActor @Sendable (URL) -> Void) -> ([URL]) -> Void {
        { urls in
            guard let url = urls.first else { return }
            Task { @MainActor in use(url) }
        }
    }
}

extension View {
    /// Keeps a state's layout in place while hiding it, so switching states inside a
    /// ZStack never changes the container's geometry. `accessible` defaults to
    /// `visible`; pass `false` for a visible skeleton VoiceOver should skip.
    func nowStateLayer(visible: Bool, accessible: Bool? = nil) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!(accessible ?? visible))
    }
}
