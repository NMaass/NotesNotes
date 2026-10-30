import ResonoteKit
import SwiftUI
import UIKit

/// The quick "you're listening to X — want to write about it?" sheet, opened from
/// the Now card, the accessory, widgets, controls, the Action button, and shared links.
///
/// It finds the song first (current track, a recent play, Shazam, or a link), then offers a prompt,
/// a few words, and tags. The song is pinned as soon as the person starts, so a track
/// change in another app never moves their words to a different song. Opened from
/// outside the app, it checks the sources before treating the song on screen as current.
/// Recent plays sit under the header: with nothing playing, the likeliest recent song is
/// attached on its own, and the next few are one tap away.
///
/// Write first, attach later: with no song in sight the person can still write. The note
/// is saved with the moment it was begun, and the listen covering that moment attaches
/// itself later (`WriteFirst`). Opened again from Drafts (`CapturePreset.noteKey`), the
/// sheet shows that song as "attached automatically" with a way to change or remove it.
struct CaptureSheet: View {
    var preset: CapturePreset
    var startsListening: Bool = false
    var link: String? = nil

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(NowPlayingService.self) private var nowPlaying
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    // What the person is writing.
    @State private var note = CaptureNote()
    @State private var lenses: [MusicLens]
    @State private var moods: [String]
    @State private var addedMoods: [String] = []
    @State private var moodDraft = ""
    @State private var genreChoices: [String: Bool] = [:]
    // Private first: publishing is the person's choice, never the default.
    @State private var isPublic = false
    @FocusState private var focus: CaptureField?

    // What it is about, and how the sheet got there.
    @State private var pinned: CapturePin?
    @State private var frozen: CaptureOrder?
    @State private var flow: CaptureFlow = .idle
    @State private var flowStartTrack: NowPlayingTrack?
    /// The current listen was asked for from the track view ("Not this song?"): a miss goes back to the track.
    @State private var identifyFromTrack = false
    @State private var work: CaptureWork = .start
    @State private var didStart = false
    @State private var requests = 0
    @State private var pinResolveRequest = 0
    /// Opened from outside the app: the song on screen may be minutes old until the sources answer.
    @State private var isCheckingSources = false
    /// The recent play the person (or the sheet, on opening) attached.
    @State private var attachedPlay: RecentPlay?
    /// The person chose the song (a recent play, Identify, a link): no "automatically attached".
    @State private var personChose = false

    // Finishing.
    @State private var confirmation: String?
    @State private var pendingExit: CaptureExit?
    @State private var detent: PresentationDetent = .medium
    /// Words this sheet put in a draft while the app was away.
    @State private var autosaved: CaptureAutosave?

    // Write first, attach later.
    /// The person chose to write with no song: the song playing now doesn't take the note.
    @State private var writingFirst = false
    /// When the person began writing: the moment a written-first note is about.
    @State private var startedWritingAt: Date?
    /// The written-first note this sheet opened (from Drafts), if any.
    @State private var writtenNote: Draft?
    /// The id a note written first in this sheet is saved under.
    @State private var freshNoteId = Identifiers.make()
    /// The person removed the note's song: nothing attaches to it on its own again.
    @State private var songDetached = false

    private enum Display: Equatable {
        case track, looking, nothing, listening, readingLink, identifyFailed, linkFailed, linkUnreachable, signInForLink
    }

    private static let primaryLabels = ["Save note", "Log listen", "Saved to your journal", "Listen logged", "Saved for its song"]
    /// The origin `appIntentRouting()` uses when a Shortcut hands over a song.
    static let shortcutOrigin = "shortcut"
    private static let customMoodLimit = 32
    /// How long capture opened from outside waits for the sources before trusting the song on screen.
    private static let sourceCheckLimit: Duration = .seconds(2.5)

    init(preset: CapturePreset, startsListening: Bool = false, link: String? = nil) {
        self.preset = preset
        self.startsListening = startsListening
        self.link = link
        _lenses = State(initialValue: preset.lens.map { [$0] } ?? [])
        let mood = preset.mood?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _moods = State(initialValue: mood.isEmpty ? [] : [mood])
        // A note from Drafts: never show the song playing now, even before it loads.
        _writingFirst = State(initialValue: preset.noteKey != nil)
    }

    var body: some View {
        let subject = self.subject
        let display = self.display(for: subject)
        let suggestions = self.suggestions(for: subject)
        lifecycle(presented(layout(subject: subject, display: display, suggestions: suggestions), subject: subject), isInSync: subject.isInSync)
    }

    // MARK: Subject

    private var subject: CaptureSubject {
        let track: NowPlayingTrack?
        let resolution: ResolveResponse?
        var phase: NowPlayingService.Phase
        var isInSync = true
        if writingFirst {
            // Written first: only a song attached to the note counts, never whatever plays now.
            track = pinned?.track
            resolution = pinned?.resolution
            phase = pinned?.isResolving == true ? .resolving : .unmatched
            isInSync = false
        } else if let pinned, !CaptureMatch.same(pinned.track, nowPlaying.track) {
            track = pinned.track
            resolution = pinned.resolution
            phase = pinned.isResolving ? .resolving : .unmatched
            isInSync = false
        } else {
            track = nowPlaying.track ?? pinned?.track
            resolution = nowPlaying.resolution ?? pinned?.resolution
            phase = nowPlaying.phase
        }
        if resolution?.song != nil, phase == .unmatched { phase = .ready }
        return CaptureSubject(track: track, resolution: resolution, phase: phase, isInSync: isInSync)
    }

    private func display(for subject: CaptureSubject) -> Display {
        // Before the first task runs, show where the sheet is headed rather than a stale track.
        if !didStart {
            if link != nil { return model.hasLiveSession || model.isRestoringSession ? .readingLink : .signInForLink }
            if startsListening { return .listening }
        }
        switch flow {
        case .listening where nowPlaying.track == flowStartTrack: return .listening
        case .readingLink: return .readingLink
        // Listening for another song from the track view: a miss goes back to that track.
        case .identifyFailed where !identifyFromTrack: return .identifyFailed
        case .linkFailed: return .linkFailed
        case .linkUnreachable: return .linkUnreachable
        case .awaitingSignIn: return .signInForLink
        case .idle, .listening, .identifyFailed: break
        }
        if subject.track != nil { return .track }
        if writingFirst { return .nothing }
        switch nowPlaying.phase {
        case .idle, .looking, .resolving: return .looking
        case .ready, .unmatched, .nothing: return .nothing
        }
    }

    private func suggestions(for subject: CaptureSubject) -> TagSuggestions {
        // Once frozen, only the song's genres are still read, so skip walking the person's history.
        if frozen != nil { return subject.resolution?.suggestions ?? TagSuggestions() }
        let habits = model.habits
        return subject.resolution?.suggestions.merged(withHabits: habits) ?? habits
    }

    /// "Artist · Album": from the catalog once the song is matched (it fills in when the
    /// catalog learns the artist), else as the source reported it.
    private func byline(for subject: CaptureSubject) -> String? {
        if let song = subject.song {
            let known = model.catalog.subtitle(for: .song(song))
            if !known.isEmpty { return known }
        }
        return subject.track?.nowByline
    }

    // MARK: Layout

    private func layout(subject: CaptureSubject, display: Display, suggestions: TagSuggestions) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RN.Space.l) {
                headerRow(subject: subject, display: display)
                statusLine(subject: subject, display: display)
                recentSection(subject: subject, display: display)
                content(subject: subject, display: display, suggestions: suggestions)
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.top, RN.Space.xl)
            .padding(.bottom, RN.Space.l)
            .disabled(confirmation != nil)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            actionBar(subject: subject, display: display, suggestions: suggestions)
        }
    }

    private func presented(_ content: some View, subject: CaptureSubject) -> some View {
        content
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(hasUnsavedText)
            .holdsUnsavedInput(hasUnsavedText)
            .confirmationDialog("Keep what you wrote?", isPresented: exitDialogIsPresented, titleVisibility: .visible) {
                let exit = pendingExit ?? .close
                if subject.song != nil || subject.track != nil || writingFirst {
                    Button("Save as draft") {
                        // A song not matched yet keeps the words with its track; they move to the
                        // song's draft once it's matched. Moods and genre picks are saved now.
                        keepWordsInDraft(subject: subject)
                        if let song = subject.song { commitWordlessTags(song: song, genres: genreOptions(subject: subject, suggestions: suggestions(for: subject))) }
                        finish(exit)
                    }
                }
                Button("Discard note", role: .destructive) {
                    dropAutosave(subject: subject)
                    finish(exit)
                }
                Button("Keep writing", role: .cancel) {}
            } message: {
                Text(writingFirst && subject.track == nil
                    ? "It waits in Drafts on the Now tab, and the song you were playing attaches when a source reports it."
                    : subject.song == nil && subject.track != nil
                    ? "It waits in Drafts on the Now tab, and joins this song's draft once Resonote matches it."
                    : "A draft stays on this device until you publish it.")
            }
            .sensoryFeedback(.success, trigger: confirmation) { _, new in new != nil }
    }

    private func lifecycle(_ content: some View, isInSync: Bool) -> some View {
        content
            .task(id: work) { await perform(work) }
            .task(id: pinResolveRequest) {
                guard pinResolveRequest > 0 else { return }
                await resolvePinned()
            }
            .task(id: confirmation) { await closeAfterConfirmation() }
            // A live session (a first sign-in, or signing in again after it expired) picks up the link or the match.
            .onChange(of: model.hasLiveSession) { _, live in continueAfterSignIn(live) }
            // iOS may end the app while it's away: the words wait in a draft until then.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { autosave() }
            }
            .onDisappear {
                if let writtenNote {
                    // A note from Drafts keeps its words and the song as the person left them;
                    // closed with its words cleared, it goes, as publishing it empty would.
                    if confirmation == nil {
                        if note.hasText { keepWordsInDraft(subject: subject) } else { model.drafts.delete(key: writtenNote.key) }
                    }
                } else if confirmation == nil, !note.hasText {
                    // Closed with the words cleared: nothing of them should linger in a draft.
                    dropAutosave(subject: subject)
                }
            }
            // Every request from outside counts, even the same one twice (Identify pressed again).
            .onChange(of: router.captureRequest) { _, _ in
                handle(CaptureRequest(preset: preset, startsListening: startsListening, link: link))
            }
            .onChange(of: nowPlaying.resolution) { _, live in follow(live) }
            .onChange(of: isInSync) { _, inSync in
                if !inSync { resolvePinnedIfNeeded() }
            }
            .onChange(of: note.hasText) { _, hasText in
                if hasText { engage() }
            }
            .onChange(of: focus) { _, field in
                if field != nil, detent != .large { detent = .large }
            }
    }

    // MARK: Header and status

    private func headerRow(subject: CaptureSubject, display: Display) -> some View {
        HStack(alignment: .top, spacing: RN.Space.s) {
            header(subject: subject, display: display)
            Button {
                requestExit(.close)
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
        }
    }

    @ViewBuilder
    private func header(subject: CaptureSubject, display: Display) -> some View {
        switch display {
        case .track:
            CaptureHeader(art: .artwork(subject.artworkURL), title: subject.track?.title ?? "", subtitle: byline(for: subject), track: subject.track)
        case .looking:
            CaptureHeader(art: .symbol("music.note"), title: "Song title", subtitle: "Artist · Album", track: nil, isPlaceholder: true)
        case .listening:
            CaptureHeader(art: .symbol("music.note"), title: "What's playing?", subtitle: "Hold your iPhone near the music.", track: nil)
        case .readingLink:
            CaptureHeader(art: .symbol("link"), title: "Shared link", subtitle: "Finding the song…", track: nil)
        case .identifyFailed:
            CaptureHeader(art: .symbol("waveform"), title: "No match this time", subtitle: "Try again, paste a link, or search.", track: nil)
        case .linkFailed:
            CaptureHeader(art: .symbol("link"), title: "That link didn't open a song", subtitle: "Try another link, or search instead.", track: nil)
        case .linkUnreachable:
            CaptureHeader(art: .symbol("link"), title: "Shared link", subtitle: "Resonote can't be reached right now.", track: nil)
        case .signInForLink:
            CaptureHeader(art: .symbol("link"), title: "Shared link", subtitle: "Sign in to note the song you shared.", track: nil)
        case .nothing where writingFirst:
            CaptureHeader(art: .symbol("square.and.pencil"), title: "Write first", subtitle: writtenFirstSubtitle, track: nil)
        case .nothing:
            CaptureHeader(art: .symbol("music.note"), title: "Nothing playing that Resonote can see.", subtitle: "Identify it, paste a link, or search.", track: nil)
        }
    }

    /// "Written 5 min ago. …": when the note is from, and what happens next.
    private var writtenFirstSubtitle: String {
        let next = songDetached ? "No song, until you pick one." : "The song you were playing attaches when a source reports it."
        guard let startedWritingAt else { return next }
        return "Written \(NowRelativeTime.phrase(since: startedWritingAt, now: Date())). \(next)"
    }

    private func statusLine(subject: CaptureSubject, display: Display) -> some View {
        var text: String?
        var showsWaveform = false
        var actionTitle: String?
        var action: (() -> Void)?
        switch display {
        case .listening:
            text = "Listening…"
            showsWaveform = true
        case .readingLink:
            text = "Matching…"
        case .looking:
            text = "Checking your sources…"
        case .identifyFailed:
            text = nowPlaying.identifyFailure?.message ?? "Couldn't place that one. Try again in a moment."
            if nowPlaying.identifyFailure == .microphoneDenied {
                actionTitle = "Open Settings"
                action = { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
            }
        case .linkFailed:
            text = "Resonote couldn't find a song at that link."
        case .linkUnreachable:
            if case .linkUnreachable(let url, let message) = flow {
                text = message
                actionTitle = "Retry"
                action = { startLink(url) }
            }
        case .nothing, .signInForLink:
            text = nil
        case .track:
            if isCheckingSources {
                text = "Checking your sources…"
                break
            }
            if flow == .identifyFailed, identifyFromTrack {
                // Listened for another song and missed: still on this one.
                text = nowPlaying.identifyFailure?.message ?? "Couldn't place that one. Try again in a moment."
                actionTitle = nowPlaying.identifyFailure == .microphoneDenied ? "Open Settings" : "Try again"
                action = nowPlaying.identifyFailure == .microphoneDenied
                    ? { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    : { startIdentify(fromTrack: true) }
                break
            }
            let status = NowMatchStatus(phase: subject.phase, resolution: subject.resolution, isSignedIn: model.hasLiveSession, isRestoring: model.isRestoringSession)
            text = status?.text
            if status == .couldNotMatch {
                actionTitle = "Retry"
                action = { retryMatch(isInSync: subject.isInSync) }
            } else if status == .signInToMatch {
                // The session ended: sign in here, over the sheet, and the match resumes.
                actionTitle = "Sign in"
                action = { signIn() }
            } else if status == .unmatched {
                // Candidates are offered as rows with artwork below; without any, search.
                if subject.candidates == nil {
                    actionTitle = "Search"
                    action = { requestExit(.search) }
                }
            }
        }
        return NowStatusLine(
            text: text,
            lines: 2,
            showsWaveform: showsWaveform,
            actionTitle: actionTitle,
            action: action
        )
    }

    // MARK: Recent plays

    /// The attached recent play and a few others as chips, while a song is on screen.
    @ViewBuilder
    private func recentSection(subject: CaptureSubject, display: Display) -> some View {
        if display == .track, model.isSignedIn, confirmation == nil {
            let attached = attachedRecent(subject: subject)
            let plays = nowPlaying.recent.plays
            if attached != nil || plays.count > 1 {
                CaptureRecentPlays(
                    plays: plays,
                    attached: attached,
                    isAutomatic: !personChose && !isCheckingSources,
                    onChoose: { choose(play: $0) },
                    onJournalingPick: { picked, icon in pickedInJournal(picked, icon: icon) },
                    isWrittenFirst: writingFirst,
                    onDetach: writingFirst ? { detachSong() } : nil
                )
            }
        }
    }

    /// The recent play the sheet's song is: the one attached, else the ranked row for the same song.
    private func attachedRecent(subject: CaptureSubject) -> RecentPlay? {
        guard let track = subject.track else { return nil }
        if let attachedPlay, CaptureMatch.same(attachedPlay.track(), track) { return attachedPlay }
        let key = TrackText.matchKey(artist: track.artist, title: track.title)
        return nowPlaying.recent.plays.first { $0.matchKey == key }
    }

    /// The person tapped a recent play: it becomes the sheet's song, words and lenses kept.
    private func choose(play: RecentPlay) {
        personChose = true
        attach(play)
    }

    private func attach(_ play: RecentPlay) {
        if flow == .identifyFailed { flow = .idle }
        attachedPlay = play
        pin(to: play.track())
        resolvePinnedIfNeeded()
    }

    /// Songs picked in the Journaling Suggestions sheet join the recent list; the newest is attached.
    private func pickedInJournal(_ plays: [RecentPlay], icon: URL?) {
        nowPlaying.addJournalingPicks(plays, icon: icon)
        let newest = plays.max { ($0.playedAt ?? .distantPast) < ($1.playedAt ?? .distantPast) }
        if let newest { choose(play: newest) }
    }

    /// Written first: the person takes the song off the note. It waits with no song, and
    /// nothing attaches on its own again; they can still pick one.
    private func detachSong() {
        personChose = true
        songDetached = true
        attachedPlay = nil
        pinned = nil
        genreChoices = [:]
    }

    /// The person chose to write with no song.
    private func startWritingFirst() {
        writingFirst = true
        if flow == .identifyFailed { flow = .idle }
        focus = .note
        if detent != .large { detent = .large }
    }

    /// Opens a written-first note from Drafts: its words, and the song attached to it.
    private func open(note saved: Draft) {
        writtenNote = saved
        writingFirst = true
        startedWritingAt = saved.writtenAt
        note.text = saved.document.plainText
        lenses = saved.lenses
        isPublic = saved.isPublic
        songDetached = saved.attachment == .person && saved.track == nil
        if let track = saved.track {
            personChose = saved.attachment == .person
            attachedPlay = RecentPlay(track: track)
            pin(to: track)
            resolvePinnedIfNeeded()
        } else {
            personChose = songDetached
        }
    }

    /// Nothing is playing: attach the likeliest recent play (`RecentPlayList.preselected`),
    /// so a note can start without anyone naming the song.
    private func attachPreselected() {
        guard pinned == nil, nowPlaying.track == nil, let preselected = nowPlaying.recent.preselected else { return }
        attach(preselected)
    }

    // MARK: Content

    @ViewBuilder
    private func content(subject: CaptureSubject, display: Display, suggestions: TagSuggestions) -> some View {
        switch display {
        case .track, .looking, .readingLink:
            if !model.isSignedIn, !model.isRestoringSession {
                Text("Sign in to write about this song. You'll come right back here.")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
            } else if display == .track {
                if nowPlaying.suggestsIdentify, !personChose {
                    CaptureIdentifyPrompt(isListening: nowPlaying.isIdentifying) { startIdentify(fromTrack: true) }
                }
                if let candidates = subject.candidates, !isCheckingSources {
                    CaptureCandidateRows(candidates: candidates, isBusy: subject.phase == .resolving) { choose($0) }
                }
                form(subject: subject, suggestions: suggestions)
            } else {
                // The form at its final size while the song is found, so arriving only swaps content.
                form(subject: subject, suggestions: suggestions)
                    .redacted(reason: .placeholder)
                    .disabled(true)
                    .accessibilityHidden(true)
            }
        case .nothing, .identifyFailed, .linkFailed, .linkUnreachable:
            if writingFirst, display == .nothing || display == .identifyFailed {
                writeFirstForm
            } else if display == .nothing || display == .identifyFailed, model.isSignedIn {
                CaptureWriteFirstButton { startWritingFirst() }
            }
            if display == .nothing || display == .identifyFailed {
                CaptureRecentChoices(
                    plays: nowPlaying.recent.plays,
                    icons: nowPlaying.journalingIcons,
                    onChoose: { choose(play: $0) },
                    onJournalingPick: { plays, icon in pickedInJournal(plays, icon: icon) }
                )
            }
            CaptureFallbackOptions(
                isListening: nowPlaying.isIdentifying,
                microphoneDenied: nowPlaying.identifyFailure == .microphoneDenied || SongRecognizer.microphoneDenied,
                onIdentify: { startIdentify() },
                onPaste: { url in startLink(url.absoluteString) },
                onSearch: { requestExit(.search) }
            )
        case .listening:
            Text("Listening for up to 15 seconds.")
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
        case .signInForLink:
            EmptyView()
        }
    }

    /// The words with no song yet: lenses and visibility travel with them; moods and
    /// genres wait for the song.
    private var writeFirstForm: some View {
        VStack(alignment: .leading, spacing: RN.Space.l) {
            CaptureNoteField(note: note, focus: $focus, isFocused: focus == .note)
            CaptureChipGroup(
                title: "What kind of thought is this?",
                items: MusicLens.allCases,
                label: \.rawValue,
                isSelected: { lenses.contains($0) },
                toggle: toggleLens
            )
            Toggle(isOn: $isPublic) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(VisibilityCopy.publicLabel)
                    VisibilityNote(isPublic: isPublic)
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                }
            }
            .tint(RN.Palette.rust)
        }
    }

    private func form(subject: CaptureSubject, suggestions: TagSuggestions) -> some View {
        VStack(alignment: .leading, spacing: RN.Space.xl) {
            VStack(alignment: .leading, spacing: RN.Space.m) {
                Text(frozen?.prompt ?? suggestions.prompt)
                    .font(RN.Typography.headline)
                    .foregroundStyle(RN.Palette.prose)
                    .lineLimit(2, reservesSpace: true)
                CaptureNoteField(note: note, focus: $focus, isFocused: focus == .note)
            }

            CaptureChipGroup(
                title: "What kind of thought is this?",
                items: lensOptions(suggestions),
                label: \.rawValue,
                isSelected: { lenses.contains($0) },
                toggle: toggleLens,
                // "Log listen" keeps moods, not lenses: say so while there are no words.
                hint: "Saved with a note",
                showsHint: !lenses.isEmpty && !note.hasText
            )

            VStack(alignment: .leading, spacing: RN.Space.s) {
                CaptureChipGroup(
                    title: "How did this listen feel?",
                    items: moodOptions(suggestions),
                    label: { $0 },
                    isSelected: { mood in moods.contains(mood) },
                    toggle: toggleMood
                )
                CaptureMoodField(text: $moodDraft, focus: $focus, onSubmit: addMood)
            }

            genreSection(subject: subject, suggestions: suggestions)

            Toggle(isOn: $isPublic) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(VisibilityCopy.publicLabel)
                    VisibilityNote(isPublic: isPublic)
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                }
            }
            .tint(RN.Palette.rust)
        }
    }

    @ViewBuilder
    private func genreSection(subject: CaptureSubject, suggestions: TagSuggestions) -> some View {
        let genres = genreOptions(subject: subject, suggestions: suggestions)
        if let songId = subject.song?.id, !genres.isEmpty {
            CaptureChipGroup(
                title: "How do you hear it?",
                items: genres,
                label: \.name,
                isSelected: { isGenreSelected($0.id, songId: songId) },
                toggle: { toggleGenre($0.id, songId: songId) }
            )
        } else {
            VStack(alignment: .leading, spacing: RN.Space.s) {
                CaptureSectionTitle("How do you hear it?")
                Text(subject.song == nil ? "Genres appear once the song is matched." : "No genre suggestions for this song yet.")
                    .font(.subheadline)
                    .foregroundStyle(RN.Palette.muted)
                    .frame(minHeight: 34, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func actionBar(subject: CaptureSubject, display: Display, suggestions: TagSuggestions) -> some View {
        if !model.isRestoringSession, display != .listening, !model.isSignedIn || display == .signInForLink {
            Button {
                // Sign-in returns here; the sheet picks up the link or the match itself.
                signIn()
            } label: {
                Text("Sign in to write")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, RN.Space.gutter)
            .padding(.vertical, RN.Space.m)
        } else if display == .track || display == .looking || display == .readingLink {
            let ready = display == .track && subject.song != nil && !isCheckingSources
            VStack(spacing: RN.Space.s) {
                Button {
                    save(subject: subject, suggestions: suggestions)
                } label: {
                    CapturePrimaryLabel(note: note, confirmation: confirmation, candidates: Self.primaryLabels)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!ready)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: RN.Space.l) { secondaryActions(subject: subject, display: display, suggestions: suggestions, ready: ready) }
                    VStack(spacing: RN.Space.xs) { secondaryActions(subject: subject, display: display, suggestions: suggestions, ready: ready) }
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, RN.Space.gutter)
            .padding(.vertical, RN.Space.m)
        } else if writingFirst, display == .nothing || display == .identifyFailed {
            Button {
                saveWithoutSong()
            } label: {
                StableLabel(confirmation ?? "Save note", among: Self.primaryLabels)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!note.hasText || confirmation != nil)
            .padding(.horizontal, RN.Space.gutter)
            .padding(.vertical, RN.Space.m)
        }
    }

    @ViewBuilder
    private func secondaryActions(subject: CaptureSubject, display: Display, suggestions: TagSuggestions, ready: Bool) -> some View {
        Button("Open full editor") {
            openEditor(subject: subject, suggestions: suggestions)
        }
        .frame(minHeight: 32)
        .disabled(!ready || confirmation != nil)
        // The song on screen isn't the one playing (a paused or earlier one): listen for it.
        Button {
            startIdentify(fromTrack: true)
        } label: {
            Label("Not this song?", systemImage: "waveform")
        }
        .frame(minHeight: 32)
        .disabled(display != .track || nowPlaying.isIdentifying || confirmation != nil)
        .accessibilityHint("Listens for the song playing nearby")
    }

    // MARK: Options

    private func lensOptions(_ suggestions: TagSuggestions) -> [MusicLens] {
        if let frozen { return frozen.lenses }
        var seen = Set<MusicLens>()
        return (suggestions.lenses + MusicLens.allCases).filter { seen.insert($0).inserted }
    }

    private func baseMoods(_ suggestions: TagSuggestions) -> [String] {
        frozen?.moods ?? Self.unique(suggestions.moods + Vocabulary.moods)
    }

    /// Suggested moods, the shared vocabulary, then the person's own words (always including what's selected).
    private func moodOptions(_ suggestions: TagSuggestions) -> [String] {
        Self.unique(baseMoods(suggestions) + addedMoods + moods)
    }

    private func genreOptions(subject: CaptureSubject, suggestions: TagSuggestions) -> [GenreSuggestion] {
        guard let song = subject.song else { return [] }
        var options = suggestions.genres
        var seen = Set(options.map(\.id))
        let asserted = (model.bundle?.genreAssertions ?? []).filter { $0.entityId == song.id }.map(\.genreId)
        for id in asserted + [preset.genreId].compactMap({ $0 }) where seen.insert(id).inserted {
            if let genre = model.catalog.genres[id] {
                options.append(GenreSuggestion(id: genre.id, name: genre.name, source: "you"))
            }
        }
        return options
    }

    private static func unique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    private func isGenreSelected(_ id: String, songId: String) -> Bool {
        genreChoices[id] ?? (model.hasAsserted(genreId: id, on: songId) || preset.genreId == id)
    }

    private func toggleLens(_ lens: MusicLens) {
        engage()
        if let index = lenses.firstIndex(of: lens) {
            lenses.remove(at: index)
        } else {
            lenses.append(lens)
        }
    }

    private func toggleMood(_ mood: String) {
        engage()
        if let index = moods.firstIndex(of: mood) {
            moods.remove(at: index)
        } else {
            moods.append(mood)
        }
    }

    private func toggleGenre(_ id: String, songId: String) {
        engage()
        genreChoices[id] = !isGenreSelected(id, songId: songId)
    }

    private func addMood() {
        let word = String(moodDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.customMoodLimit))
        moodDraft = ""
        guard !word.isEmpty else { return }
        engage()
        if !addedMoods.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { addedMoods.append(word) }
        if !moods.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { moods.append(word) }
    }

    // MARK: Writing

    private var hasUnsavedText: Bool {
        // A note opened from Drafts is already kept; closing saves the changes.
        confirmation == nil && note.hasText && writtenNote == nil
    }

    /// Selected moods plus a word still sitting in the "your own word" field.
    private var finalMoods: [String] {
        let pending = String(moodDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.customMoodLimit))
        guard !pending.isEmpty, !moods.contains(where: { $0.caseInsensitiveCompare(pending) == .orderedSame }) else { return moods }
        return moods + [pending]
    }

    /// Pins the song and freezes chip order the first time the person does anything.
    /// While the sources are still being checked the song isn't pinned yet: the check
    /// may replace it, and pins once it answers.
    private func engage() {
        if flow == .identifyFailed, identifyFromTrack { flow = .idle }
        if startedWritingAt == nil, note.hasText { startedWritingAt = Date() }
        if pinned == nil, !isCheckingSources, !writingFirst, let current = nowPlaying.track {
            pinned = CapturePin(track: current, resolution: nowPlaying.resolution)
        }
        if frozen == nil {
            let suggestions = suggestions(for: subject)
            frozen = CaptureOrder(lenses: lensOptions(suggestions), moods: baseMoods(suggestions), prompt: suggestions.prompt)
        }
    }

    private func save(subject: CaptureSubject, suggestions: TagSuggestions) {
        guard confirmation == nil, !isCheckingSources, let song = subject.song else { return }
        let genres = genreOptions(subject: subject, suggestions: suggestions)
        model.requireAuth { commit(song: song, genres: genres) }
    }

    private func commit(song: Song, genres: [GenreSuggestion]) {
        guard confirmation == nil else { return }
        let body = note.trimmed
        let chosenMoods = finalMoods
        var wroteEntry = false
        if let writtenNote, model.isSignedIn {
            // Written first: the entry is dated when the words were, and its draft goes.
            if body.isEmpty {
                model.drafts.delete(key: writtenNote.key)
            } else {
                model.saveWrittenNote(writtenNote, text: body, songId: song.id, lenses: lenses, isPublic: isPublic)
                wroteEntry = true
            }
        } else if !body.isEmpty, model.isSignedIn {
            let now = ResonoteDate.now()
            let document = RichDocument.plain(body)
            model.save(JournalEntry(
                id: Identifiers.make(),
                profileId: model.profile?.id ?? "",
                entityId: song.id,
                entityKind: .song,
                document: document,
                plainText: document.plainText,
                lenses: lenses,
                references: [],
                isPublic: isPublic,
                createdAt: now,
                updatedAt: now
            ))
            wroteEntry = true
        }
        if !chosenMoods.isEmpty || !wroteEntry {
            model.logListen(songId: song.id, moods: chosenMoods, note: wroteEntry || body.isEmpty ? nil : body)
        }
        let entity = CatalogEntity.song(song)
        for genre in genres {
            model.setGenre(genre.id, on: entity, asserted: isGenreSelected(genre.id, songId: song.id))
        }
        // Saved for real: words autosaved to a draft while the app was away aren't needed there.
        dropAutosave(subject: subject)
        focus = nil
        let message = wroteEntry ? "Saved to your journal" : "Listen logged"
        confirmation = message
        AccessibilityNotification.Announcement(message).post()
    }

    /// Hands the words and lenses to the full editor. Moods and genre picks have no place
    /// there, so they are saved now (a listen and genre tags) rather than dropped.
    private func openEditor(subject: CaptureSubject, suggestions: TagSuggestions) {
        guard let song = subject.song else { return }
        commitWordlessTags(song: song, genres: genreOptions(subject: subject, suggestions: suggestions))
        // An autosaved copy is brought up to date, so the editor finds these exact words in
        // the draft and doesn't add them twice.
        if autosaved != nil { keepWordsInDraft(subject: subject) }
        router.present(.compose(ComposerContext(
            entityKind: .song,
            entityId: song.id,
            seed: CaptureSeed(text: note.trimmed, lenses: lenses, isPublic: isPublic)
        )))
    }

    /// Saves what needs no words: the chosen moods as a listen, and genre picks
    /// (including a tag tapped on the widget).
    private func commitWordlessTags(song: Song, genres: [GenreSuggestion]) {
        guard model.isSignedIn else { return }
        let chosenMoods = finalMoods
        if !chosenMoods.isEmpty { model.logListen(songId: song.id, moods: chosenMoods, note: nil) }
        let entity = CatalogEntity.song(song)
        for genre in genres {
            model.setGenre(genre.id, on: entity, asserted: isGenreSelected(genre.id, songId: song.id))
        }
    }

    // MARK: Keeping the words

    /// Puts the words in the person's draft for this song (or, unmatched, for its track),
    /// replacing what an earlier autosave put there instead of adding it twice.
    @discardableResult
    private func keepWordsInDraft(subject: CaptureSubject) -> Bool {
        let drafts = model.drafts
        if writingFirst, writtenNote != nil || subject.track == nil {
            return keepNote(subject: subject, in: drafts)
        }
        let target: String?
        if let song = subject.song {
            target = Draft.key(kind: .song, entityId: song.id, entryId: nil)
        } else if let track = subject.track {
            target = Draft.key(for: track)
        } else {
            target = nil
        }
        retractAutosave(from: drafts, also: target)
        let words = note.trimmed
        guard !words.isEmpty, let target else { return false }
        if let song = subject.song {
            drafts.append(words, lenses: lenses, isPublic: isPublic, kind: .song, entityId: song.id)
        } else if let track = subject.track {
            drafts.appendUnmatched(words, lenses: lenses, isPublic: isPublic, track: track)
        }
        autosaved = CaptureAutosave(key: target, text: words)
        return true
    }

    /// Keeps the words as a written-first note, with the song the person chose (or their
    /// removing it). An automatic attachment stays automatic.
    private func keepNote(subject: CaptureSubject, in drafts: DraftStore) -> Bool {
        let noteId = writtenNote?.noteId ?? freshNoteId
        let key = Draft.noteKey(noteId)
        // An earlier autosave of this note is replaced below; one elsewhere is taken back.
        if let previous = autosaved, previous.key != key { drafts.retract(previous.text, fromKey: previous.key) }
        // Words cleared since this note's autosave: the note held only them, so it goes.
        if let previous = autosaved, previous.key == key, writtenNote == nil, note.trimmed.isEmpty { drafts.delete(key: key) }
        autosaved = nil
        let chosen: NowPlayingTrack? = personChose ? subject.track : nil
        let attachment: Draft.Attachment? = personChose && (chosen != nil || songDetached) ? .person : nil
        guard drafts.saveNote(note.trimmed, lenses: lenses, isPublic: isPublic, writtenAt: startedWritingAt ?? Date(), noteId: noteId, track: chosen, attachment: attachment) != nil else { return false }
        if writtenNote == nil { autosaved = CaptureAutosave(key: key, text: note.trimmed) }
        return true
    }

    /// Saves the words with no song. The listen covering the moment they were begun
    /// attaches when any source reports it.
    private func saveWithoutSong() {
        guard confirmation == nil, note.hasText else { return }
        model.requireAuth {
            guard keepNote(subject: subject, in: model.drafts) else { return }
            // The note is saved for real, not an autosave to take back.
            autosaved = nil
            model.attachWrittenNotes(to: nowPlaying.recent.plays)
            focus = nil
            let message = "Saved for its song"
            confirmation = message
            AccessibilityNotification.Announcement("Saved. The song you were playing attaches when a source reports it.").post()
        }
    }

    /// The app is leaving the foreground: keep the words safe in a draft.
    private func autosave() {
        guard confirmation == nil, model.isSignedIn, note.hasText || autosaved != nil else { return }
        keepWordsInDraft(subject: subject)
    }

    /// Takes back autosaved words (they were published, discarded, or cleared).
    private func dropAutosave(subject: CaptureSubject) {
        guard autosaved != nil else { return }
        retractAutosave(from: model.drafts, also: subject.song.map { Draft.key(kind: .song, entityId: $0.id, entryId: nil) })
    }

    /// Removes the last autosave from its draft, and from `key` too: matching the song
    /// moves words kept with its track over to the song's draft.
    private func retractAutosave(from drafts: DraftStore, also key: String?) {
        guard let previous = autosaved else { return }
        drafts.retract(previous.text, fromKey: previous.key)
        if let key, key != previous.key { drafts.retract(previous.text, fromKey: key) }
        autosaved = nil
    }

    private func closeAfterConfirmation() async {
        guard confirmation != nil else { return }
        try? await Task.sleep(for: .seconds(1.1))
        guard !Task.isCancelled else { return }
        dismiss()
    }

    // MARK: Leaving

    private var exitDialogIsPresented: Binding<Bool> {
        Binding(
            get: { pendingExit != nil },
            set: { presented in if !presented { pendingExit = nil } }
        )
    }

    /// Closing with words in the field asks first; drafts are the person's.
    private func requestExit(_ exit: CaptureExit) {
        if hasUnsavedText {
            pendingExit = exit
        } else {
            finish(exit)
        }
    }

    private func finish(_ exit: CaptureExit) {
        pendingExit = nil
        if exit == .search { router.tab = .search }
        dismiss()
    }

    // MARK: Finding the song

    private func perform(_ work: CaptureWork) async {
        switch work {
        case .start:
            guard !didStart else { return }
            didStart = true
            await start()
        case .identify:
            await runIdentify()
        case .link(let url, _):
            await runLink(url)
        case .resolveCurrent:
            guard nowPlaying.track != nil, nowPlaying.resolution == nil, nowPlaying.phase == .unmatched else { return }
            // The service owns the request: closing the sheet doesn't cancel it halfway.
            await nowPlaying.resolveCurrent()
        case .checkSources:
            await checkSources()
        }
    }

    private func start() async {
        let external = router.consumeExternalCapture()
        if let key = preset.noteKey {
            await model.waitUntilRestored()
            if let saved = model.drafts.load(key: key), saved.isWrittenFirst { open(note: saved) }
            return
        }
        if let link {
            await runLink(link)
        } else if startsListening {
            await runIdentify()
        } else if preset.origin == Self.shortcutOrigin, nowPlaying.track?.source == .manual, let handed = nowPlaying.track {
            // A Shortcut named this song: keep it even if a source reports something else next.
            pin(to: handed)
        } else {
            if nowPlaying.track == nil {
                await nowPlaying.refresh()
            } else if external {
                await checkSources()
            }
            // Something audible that no source can name: listen on its own only when the
            // person turned that on in Settings (it opens the microphone).
            if nowPlaying.autoIdentify, nowPlaying.suggestsIdentify, !Task.isCancelled {
                await runIdentify()
                if flow == .identifyFailed, nowPlaying.recent.preselected != nil {
                    flow = .idle
                    attachPreselected()
                }
            } else {
                attachPreselected()
            }
        }
    }

    /// Opened from outside the app (the Action button, a widget): ask the sources before
    /// treating the song on screen as current. Saving waits, and a note started meanwhile
    /// is pinned to whatever the sources say.
    private func checkSources() async {
        isCheckingSources = true
        let nowPlaying = nowPlaying
        // The Music app answers at once; a slow network gets a moment, then the song on
        // screen is the best known. The refresh itself carries on either way.
        let refresh = Task { await nowPlaying.refresh() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await refresh.value }
            group.addTask { try? await Task.sleep(for: Self.sourceCheckLimit) }
            await group.next()
            group.cancelAll()
        }
        isCheckingSources = false
        if note.hasText || frozen != nil { engage() }
    }

    /// A new request arrived while the sheet is up (the Action button, a widget tag, a
    /// shared link): act on it here, keeping whatever the person has written.
    private func handle(_ request: CaptureRequest) {
        guard didStart else { return }
        let external = router.consumeExternalCapture()
        if let link = request.link {
            startLink(link)
        } else if request.startsListening {
            // Identify pressed again while listening: the listen already running answers it.
            if flow != .listening, !nowPlaying.isIdentifying { startIdentify() }
        } else if external, pinned == nil, !flow.isFindingSong {
            // Never cut short a listen or a link being read; their answer is the song.
            requests += 1
            work = .checkSources(requests)
        }
        if let lens = request.preset.lens, !lenses.contains(lens) { lenses.append(lens) }
        let mood = request.preset.mood?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !mood.isEmpty, !moods.contains(where: { $0.caseInsensitiveCompare(mood) == .orderedSame }) { moods.append(mood) }
    }

    private func startIdentify(fromTrack: Bool = false) {
        identifyFromTrack = fromTrack
        requests += 1
        work = .identify(requests)
    }

    private func startLink(_ url: String) {
        requests += 1
        work = .link(url, requests)
    }

    /// Listens with Shazam. Closing the sheet cancels this task, which stops listening.
    private func runIdentify() async {
        flowStartTrack = nowPlaying.track
        flow = .listening
        var found = await nowPlaying.identify()
        if found == nil, nowPlaying.isIdentifying {
            // Another surface (the Action button, a control) is already listening: wait for its answer.
            let before = nowPlaying.lastIdentified
            while nowPlaying.isIdentifying, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if nowPlaying.identifyFailure == nil, let heard = nowPlaying.lastIdentified, heard != before { found = heard }
        }
        guard !Task.isCancelled else {
            // Replaced by another request (a link) or the sheet closing: don't stay on "Listening…".
            if flow == .listening { flow = .idle }
            return
        }
        if let found {
            // Pin what Shazam heard, whatever another source reported while it listened.
            personChose = true
            pin(to: found)
            flow = .idle
            AccessibilityNotification.Announcement("Found \(found.title)").post()
        } else {
            flow = .identifyFailed
        }
    }

    private func runLink(_ url: String) async {
        await model.waitUntilRestored()
        guard model.hasLiveSession else {
            flow = .awaitingSignIn(url)
            return
        }
        flow = .readingLink
        let nowPlaying = nowPlaying
        // Unstructured, so closing the sheet doesn't leave the service halfway through.
        let outcome = await Task { await nowPlaying.resolve(link: url) }.value
        nowPlaying.dismissCopiedLink()
        guard !Task.isCancelled else {
            if flow == .readingLink { flow = .idle }
            return
        }
        switch outcome {
        case .found(let found):
            personChose = true
            pin(to: found)
            flow = .idle
        case .superseded:
            // The person picked another song meanwhile; the sheet shows that one.
            flow = .idle
        case .needsSignIn:
            flow = .awaitingSignIn(url)
        case .unreachable(let message):
            flow = .linkUnreachable(url: url, message: message)
        case .noSong:
            flow = .linkFailed
        }
    }

    /// Makes `track` the sheet's song. Words and lenses carry over; genre picks belong to the old song.
    private func pin(to track: NowPlayingTrack) {
        if let pinned, CaptureMatch.same(pinned.track, track) { return }
        let resolution = CaptureMatch.same(nowPlaying.track, track) ? nowPlaying.resolution : nil
        pinned = CapturePin(track: track, resolution: resolution)
        genreChoices = [:]
        songDetached = false
    }

    private func signIn() {
        if model.sessionExpired { model.renewSession() } else { model.requireAuth {} }
    }

    private func continueAfterSignIn(_ signedIn: Bool) {
        guard signedIn else { return }
        if case .awaitingSignIn(let url) = flow {
            startLink(url)
        } else if !subject.isInSync {
            resolvePinnedIfNeeded()
        } else {
            requests += 1
            work = .resolveCurrent(requests)
        }
    }

    private func retryMatch(isInSync: Bool) {
        if isInSync {
            requests += 1
            work = .resolveCurrent(requests)
        } else {
            resolvePinnedIfNeeded()
        }
    }

    /// Keeps the pinned copy of the resolution current while the service still holds the same song.
    private func follow(_ live: ResolveResponse?) {
        guard var current = pinned, let live, CaptureMatch.same(current.track, nowPlaying.track), current.resolution != live else { return }
        current.resolution = live
        pinned = current
    }

    private func resolvePinnedIfNeeded() {
        guard let pinned, pinned.resolution == nil, !pinned.isResolving, model.hasLiveSession else { return }
        pinResolveRequest += 1
    }

    /// Matches the pinned song after the service has moved on to another track.
    private func resolvePinned() async {
        guard var current = pinned, current.resolution == nil, model.hasLiveSession else { return }
        let target = current.track
        current.isResolving = true
        pinned = current
        let api = model.api
        let response = await Task { try? await api.resolve(ResolveRequest(track: target)) }.value
        guard var latest = pinned, CaptureMatch.same(latest.track, target) else { return }
        latest.isResolving = false
        if var response {
            if response.track == nil { response.track = target }
            absorb(response)
            latest.resolution = response
            if let song = response.song { model.drafts.attachUnmatched(target, toSong: song.id) }
        }
        pinned = latest
    }

    private func choose(_ candidate: SearchResult) {
        engage()
        if subject.isInSync {
            Task { await nowPlaying.choose(candidate) }
        } else {
            Task { await choosePinned(candidate) }
        }
    }

    /// Imports a candidate for the pinned song (the service's `choose` acts on its current track).
    private func choosePinned(_ candidate: SearchResult) async {
        guard case .song(let candidateSong) = candidate.entity, let mbid = candidateSong.musicbrainzId,
              var current = pinned, var resolved = current.resolution else { return }
        let target = current.track
        current.isResolving = true
        pinned = current
        let api = model.api
        let slice = await Task { try? await api.importFromMusicBrainz(kind: .song, mbid: mbid) }.value
        guard var latest = pinned, CaptureMatch.same(latest.track, target) else { return }
        latest.isResolving = false
        if let slice {
            model.absorb(slice)
            if let song = slice.songs.first(where: { $0.musicbrainzId == mbid }) ?? slice.songs.first {
                resolved.song = song
                resolved.album = song.albumId.flatMap { id in slice.albums.first { $0.id == id } }
                resolved.artist = slice.artists.first { $0.id == song.artistId }
                resolved.confidence = .strong
                resolved.candidates = []
                latest.resolution = resolved
                model.drafts.attachUnmatched(target, toSong: song.id)
            }
        }
        pinned = latest
    }

    private func absorb(_ response: ResolveResponse) {
        if let artist = response.artist { model.absorb(.artist(artist)) }
        if let album = response.album { model.absorb(.album(album)) }
        if let song = response.song { model.absorb(.song(song)) }
    }
}

/// "Save note" or "Log listen" in one fixed-size cell. Its own view, so it is the only
/// thing outside the field that redraws when the note goes from empty to written.
private struct CapturePrimaryLabel: View {
    let note: CaptureNote
    let confirmation: String?
    let candidates: [String]

    var body: some View {
        StableLabel(confirmation ?? (note.hasText ? "Save note" : "Log listen"), among: candidates)
    }
}
