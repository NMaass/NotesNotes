import ResonoteKit
import SwiftUI

/// "You're listening to X — want to write about it?" The card's geometry is the
/// same whether a track is known, still being looked for, or nothing is playing:
/// every state is laid out in the same slots and only the visible layer changes.
struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mode: Equatable { case track, looking, nothing }

    private static let vinylSize: CGFloat = 104
    private static let chipLimit = 6

    private var mode: Mode {
        if nowPlaying.track != nil { return .track }
        return nowPlaying.phase == .nothing ? .nothing : .looking
    }

    var body: some View {
        let mode = self.mode
        let track = nowPlaying.track
        VStack(alignment: .leading, spacing: RN.Space.m) {
            heading(mode: mode, track: track)
                .padding(.bottom, RN.Space.xs)
            statusLine(mode: mode)
            ZStack(alignment: .topLeading) {
                trackActions
                    .redacted(reason: mode == .looking ? .placeholder : [])
                    .disabled(mode != .track)
                    .nowStateLayer(visible: mode != .nothing, accessible: mode == .track)
                nothingActions
                    .nowStateLayer(visible: mode == .nothing)
            }
        }
        .padding(RN.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .animation(reduceMotion ? nil : RN.Motion.settle, value: mode)
        .task(id: model.hasLiveSession) { await matchAfterSignIn() }
    }

    // MARK: Heading

    private func heading(mode: Mode, track: NowPlayingTrack?) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: RN.Space.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: RN.Space.l))
        let artwork = nowPlaying.nowArtworkURL
        return layout {
            VinylView(artworkURL: artwork, title: track?.title ?? "", isPlaying: track != nil && nowPlaying.isConfirmedPlaying, size: Self.vinylSize)
                .accessibilityHidden(track == nil)
            ZStack(alignment: .leading) {
                NowTitleBlock(title: track?.title ?? "Song title", subtitle: track == nil ? "Artist · Album" : nowPlaying.byline(catalog: model.catalog)) {
                    if let track {
                        NowSourceText(track: track)
                    } else {
                        Text("Apple Music · playing")
                    }
                }
                .redacted(reason: mode == .looking ? .placeholder : [])
                .nowStateLayer(visible: mode != .nothing, accessible: mode == .track)

                VStack(alignment: .leading, spacing: RN.Space.xs) {
                    Text("Nothing playing that Resonote can see.")
                        .font(RN.Typography.headline)
                        .foregroundStyle(RN.Palette.ink)
                    Text("Play something in Apple Music, connect Last.fm, or let Resonote listen.")
                        .font(.subheadline)
                        .foregroundStyle(RN.Palette.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .nowStateLayer(visible: mode == .nothing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Status

    private func statusLine(mode: Mode) -> some View {
        let status = NowMatchStatus(phase: nowPlaying.phase, resolution: nowPlaying.resolution, isSignedIn: model.hasLiveSession, isRestoring: model.isRestoringSession)
        let text: String? = switch mode {
        case .track: status?.text
        case .looking: "Checking your sources…"
        case .nothing: nil
        }
        let action: (() -> Void)?
        let actionTitle: String?
        switch (mode, status) {
        case (.track, .couldNotMatch?):
            actionTitle = "Retry"
            action = { Task { await nowPlaying.resolveCurrent() } }
        case (.track, .signInToMatch?):
            actionTitle = "Sign in"
            // The sign-in task resolves the track once a session exists.
            action = { model.sessionExpired ? model.renewSession() : model.requireAuth {} }
        default:
            actionTitle = nil
            action = nil
        }
        return NowStatusLine(
            text: text,
            actionTitle: actionTitle,
            action: action,
            candidates: mode == .track ? unmatchedCandidates : nil,
            isChoosing: nowPlaying.phase == .resolving,
            onChoose: { candidate in Task { await nowPlaying.choose(candidate) } }
        )
    }

    /// A weak match's candidates, offered from the status line's menu so they never push the card's actions.
    private var unmatchedCandidates: [SearchResult]? {
        guard nowPlaying.track != nil, nowPlaying.song == nil,
              let candidates = nowPlaying.resolution?.candidates, !candidates.isEmpty else { return nil }
        return candidates
    }

    // MARK: With a track

    private var trackActions: some View {
        let song = nowPlaying.song
        return VStack(alignment: .leading, spacing: RN.Space.m) {
            Button {
                router.present(.capture(CapturePreset(origin: "now")))
            } label: {
                Label("Write about this", systemImage: "square.and.pencil")
            }
            .buttonStyle(.solid)

            secondaryLayout {
                Button {
                    guard let song else { return }
                    model.requireAuth { router.present(.logListen(songId: song.id)) }
                } label: {
                    Label("Log listen", systemImage: "headphones")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.outline)
                .disabled(song == nil)

                Button {
                    guard let song else { return }
                    router.push(.entity(kind: .song, id: song.id))
                } label: {
                    Label("Open song", systemImage: "arrow.up.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.outline)
                .disabled(song == nil)
            }

            suggestionChips

            otherSongRow
        }
    }

    /// The song shown may be an old or paused one: listen for what's actually playing, or
    /// note a song copied from another app. One fixed-height row in every state.
    private var otherSongRow: some View {
        HStack(spacing: RN.Space.m) {
            // Another app is audible and nothing vouches for this song: say so, louder.
            Button {
                router.present(.identify)
            } label: {
                Label(nowPlaying.suggestsIdentify ? "Something else playing? Identify" : "Not this song? Identify", systemImage: "waveform")
                    .font(.subheadline.weight(nowPlaying.suggestsIdentify ? .semibold : .medium))
                    .foregroundStyle(nowPlaying.suggestsIdentify ? RN.Palette.rustText : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(nowPlaying.isIdentifying)
            .accessibilityHint("Listens for the song playing nearby")
            Spacer(minLength: 0)
            PasteButton(payloadType: URL.self, onPaste: NowPaste.handler { [router, nowPlaying] url in
                nowPlaying.dismissCopiedLink()
                router.present(.resolveLink(url.absoluteString))
            })
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .nowStateLayer(visible: nowPlaying.copiedLinkAvailable)
        }
        .frame(minHeight: 34)
    }

    private var secondaryLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: RN.Space.s))
            : AnyLayout(HStackLayout(spacing: RN.Space.s))
    }

    // MARK: Suggestions

    private struct SuggestionChip: Identifiable {
        let id: String
        let title: String
        let preset: CapturePreset
    }

    /// Lenses, moods, and genres interleaved, so whatever fits on one line is varied.
    private var chips: [SuggestionChip] {
        let suggestions = nowPlaying.suggestions
        let groups: [[SuggestionChip]] = [
            suggestions.lenses.map { SuggestionChip(id: "lens-\($0.rawValue)", title: $0.rawValue, preset: CapturePreset(lens: $0, origin: "now")) },
            suggestions.moods.map { SuggestionChip(id: "mood-\($0)", title: $0, preset: CapturePreset(mood: $0, origin: "now")) },
            suggestions.genres.map { SuggestionChip(id: "genre-\($0.id)", title: $0.name, preset: CapturePreset(genreId: $0.id, origin: "now")) },
        ]
        var result: [SuggestionChip] = []
        var seen = Set<String>()
        let depth = groups.map(\.count).max() ?? 0
        for index in 0..<depth {
            for group in groups where index < group.count && seen.insert(group[index].id).inserted {
                result.append(group[index])
            }
        }
        return Array(result.prefix(Self.chipLimit))
    }

    /// One line of chips: as many as fit (up to six), never wrapping.
    private var suggestionChips: some View {
        let chips = self.chips
        return ViewThatFits(in: .horizontal) {
            chipLine(chips, count: 6)
            chipLine(chips, count: 5)
            chipLine(chips, count: 4)
            chipLine(chips, count: 3)
            chipLine(chips, count: 2)
            chipLine(chips, count: 1)
        }
        .frame(minHeight: 34, alignment: .leading)
    }

    private func chipLine(_ chips: [SuggestionChip], count: Int) -> some View {
        HStack(spacing: RN.Space.s) {
            ForEach(chips.prefix(count)) { chip in
                Chip(chip.title) {
                    router.present(.capture(chip.preset))
                }
                .accessibilityHint("Starts a note with this tag")
            }
        }
    }

    // MARK: Nothing playing

    private var nothingActions: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            Button {
                router.present(.identify)
            } label: {
                Label("Identify", systemImage: "waveform")
            }
            .buttonStyle(.solid)
            .accessibilityHint("Listens for the song playing nearby")

            Button {
                router.push(.settings)
            } label: {
                Label("Connect a source", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.outline)

            copiedLinkRow
        }
    }

    /// The copied-link row, or a hint in its place. The system paste button reads the
    /// clipboard only when tapped, so iOS never shows a paste prompt.
    private var copiedLinkRow: some View {
        ZStack(alignment: .leading) {
            Text("Or share a song to Resonote from Spotify, Apple Music, or YouTube Music.")
                .font(.footnote)
                .foregroundStyle(RN.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .nowStateLayer(visible: !nowPlaying.copiedLinkAvailable)
            HStack(spacing: RN.Space.m) {
                Text("Note the song you copied")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RN.Palette.ink)
                Spacer(minLength: 0)
                PasteButton(payloadType: URL.self, onPaste: NowPaste.handler { [router, nowPlaying] url in
                    nowPlaying.dismissCopiedLink()
                    router.present(.resolveLink(url.absoluteString))
                })
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
            }
            .nowStateLayer(visible: nowPlaying.copiedLinkAvailable)
        }
        .frame(minHeight: 34)
    }

    // MARK: Matching

    /// A track seen while signed out (or offline) is matched once a session exists. The
    /// service owns the request, so leaving the tab doesn't cancel it halfway.
    private func matchAfterSignIn() async {
        guard model.hasLiveSession, nowPlaying.track != nil, nowPlaying.resolution == nil, nowPlaying.phase == .unmatched else { return }
        await nowPlaying.resolveCurrent()
    }
}
