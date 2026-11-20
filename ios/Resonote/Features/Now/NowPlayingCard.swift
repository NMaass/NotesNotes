import ResonoteKit
import SwiftUI

/// The Now tab's hero: the record and its tonearm, the song, one status line, and one
/// primary action. Every state (a track, still looking, nothing playing) uses the same
/// slots and only the visible layer changes, so nothing below it moves. Secondary
/// actions live in `NowActionsMenu` in the navigation bar.
struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mode: Equatable { case track, looking, nothing }

    private static let recordSize: CGFloat = 270
    private static let playSize: CGFloat = 40

    private var mode: Mode {
        if nowPlaying.track != nil { return .track }
        return nowPlaying.phase == .nothing ? .nothing : .looking
    }

    var body: some View {
        let mode = self.mode
        let track = nowPlaying.track
        VStack(alignment: .leading, spacing: RN.Space.l) {
            RecordPlayerView(
                artworkURL: nowPlaying.nowArtworkURL,
                title: track?.title ?? "",
                isPlaying: track != nil && nowPlaying.isConfirmedPlaying,
                size: Self.recordSize
            )
            .accessibilityHidden(track == nil)
            .padding(.top, RN.Space.s)

            heading(mode: mode, track: track)
            statusLine(mode: mode)
            ZStack(alignment: .topLeading) {
                Button {
                    router.present(.capture(CapturePreset(origin: "now")))
                } label: {
                    Text("Write about this")
                }
                .buttonStyle(.solid)
                .disabled(mode != .track)
                .nowStateLayer(visible: mode != .nothing, accessible: mode == .track)

                nothingAction
                    .nowStateLayer(visible: mode == .nothing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : RN.Motion.settle, value: mode)
        .task(id: model.hasLiveSession) { await matchAfterSignIn() }
    }

    // MARK: Heading

    private func heading(mode: Mode, track: NowPlayingTrack?) -> some View {
        ZStack(alignment: .leading) {
            NowTitleBlock(title: track?.title ?? "Song title", subtitle: track == nil ? "Artist · Album" : nowPlaying.byline(catalog: model.catalog)) {
                if let track {
                    NowSourceText(track: track)
                } else {
                    Text("Apple Music · playing")
                }
            }
            .redacted(reason: mode == .looking ? .placeholder : [])
            .padding(.trailing, Self.playSize + RN.Space.s)
            .nowStateLayer(visible: mode != .nothing, accessible: mode == .track)

            // Play sits at the title's trailing edge, in the same slot in every state.
            PlayIconButton(target: playTarget, size: Self.playSize)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .nowStateLayer(visible: mode == .track)

            VStack(alignment: .leading, spacing: RN.Space.xs) {
                Text("Nothing playing")
                    .font(RN.Typography.headline)
                    .foregroundStyle(RN.Palette.ink)
                Text(nothingMessage)
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .nowStateLayer(visible: mode == .nothing)
        }
    }

    private var nothingMessage: String {
        if let failure = nowPlaying.spotify.failure { return failure }
        if nowPlaying.canOfferSpotify || !nowPlaying.isAppleMusicOn {
            return "Connect where you listen, and the song you're playing shows up here."
        }
        return "Play something and it shows up here."
    }

    // MARK: Status

    private func statusLine(mode: Mode) -> some View {
        let status = NowMatchStatus(phase: nowPlaying.phase, resolution: nowPlaying.resolution, isSignedIn: model.hasLiveSession, isRestoring: model.isRestoringSession)
        let playbackMessage = mode == .track ? nowPlaying.playback.message(for: playTarget) : nil
        let text: String? = switch mode {
        case .track: playbackMessage ?? status?.text
        case .looking: "Checking your sources…"
        case .nothing: nil
        }
        let action: (() -> Void)?
        let actionTitle: String?
        switch (mode, status) {
        case (.track, _) where playbackMessage != nil:
            actionTitle = nil
            action = nil
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

    /// The song shown, as something Play can start: the catalog song when matched, with
    /// the track's ISRC and links, else the track itself.
    private var playTarget: PlaybackTarget? {
        guard let track = nowPlaying.track else { return nil }
        if let song = nowPlaying.song {
            return PlaybackTarget(song: song, artistName: model.catalog.artists[song.artistId]?.name, track: track)
        }
        return PlaybackTarget(track: track)
    }

    // MARK: Nothing playing

    /// When nothing is playing: one big button for each source not yet connected, side
    /// by side in the slot the Write button keeps. Identify lives in the bar above the tabs.
    @ViewBuilder
    private var nothingAction: some View {
        let spotify = nowPlaying.canOfferSpotify
        let appleMusic = !nowPlaying.isAppleMusicOn
        if spotify || appleMusic {
            HStack(spacing: RN.Space.s) {
                if spotify { SpotifySignInButton() }
                if appleMusic { AppleMusicConnectButton() }
            }
            .buttonStyle(.solid)
        }
    }

    // MARK: Matching

    /// A track seen while signed out (or offline) is matched once a session exists. The
    /// service owns the request, so leaving the tab doesn't cancel it halfway.
    private func matchAfterSignIn() async {
        guard model.hasLiveSession, nowPlaying.track != nil, nowPlaying.resolution == nil, nowPlaying.phase == .unmatched else { return }
        await nowPlaying.resolveCurrent()
    }
}

/// The Now tab's secondary actions, in one menu in the navigation bar.
struct NowActionsMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying

    var body: some View {
        let song = nowPlaying.song
        Menu {
            if let song {
                Button {
                    model.requireAuth { router.present(.logListen(songId: song.id)) }
                } label: {
                    Label("Log listen", systemImage: "headphones")
                }
                Button {
                    router.push(.entity(kind: .song, id: song.id))
                } label: {
                    Label("Open song", systemImage: "arrow.up.right")
                }
            }
            if AppFeatures.identify {
                Button {
                    router.present(.identify)
                } label: {
                    Label(nowPlaying.track == nil ? "Identify" : "Not this song? Identify", systemImage: "waveform")
                }
                .disabled(nowPlaying.isIdentifying)
            }
            Divider()
            Button {
                router.push(.feed)
            } label: {
                Label("Published by others", systemImage: "text.book.closed")
            }
            Button {
                router.push(.settings)
            } label: {
                Label("Sources and settings", systemImage: "gearshape")
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

/// Notes a song link copied from another app. The system paste button reads the
/// clipboard only when tapped, so iOS never shows a paste prompt.
struct NowPasteButton: View {
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying

    var body: some View {
        PasteButton(payloadType: URL.self, onPaste: NowPaste.handler { [router, nowPlaying] url in
            nowPlaying.dismissCopiedLink()
            router.present(.resolveLink(url.absoluteString))
        })
        .buttonBorderShape(.capsule)
        .labelStyle(.iconOnly)
    }
}
