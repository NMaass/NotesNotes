import ResonoteKit
import SwiftUI
import UIKit

// Types and views the capture sheet is assembled from.

// MARK: - Subject

/// The song a capture is about once the person has started on it. Pinned so a new
/// track from Apple Music (or a refresh) never swaps the song out from under what
/// they are writing.
struct CapturePin: Equatable {
    var track: NowPlayingTrack
    var resolution: ResolveResponse?
    var isResolving = false
}

/// What the sheet shows right now: the pinned song, or whatever the service has.
struct CaptureSubject {
    var track: NowPlayingTrack?
    var resolution: ResolveResponse?
    var phase: NowPlayingService.Phase
    /// `false` when the pinned song is no longer the service's current track.
    var isInSync: Bool

    var song: Song? { resolution?.song }

    var artworkURL: String? { resolution?.nowArtworkURL(for: track) ?? track?.artworkURL }

    /// Candidates to offer while there is no confident match.
    var candidates: [SearchResult]? {
        guard song == nil, let candidates = resolution?.candidates, !candidates.isEmpty else { return nil }
        return candidates
    }
}

enum CaptureMatch {
    /// Whether two reports are the same song, even when one source adds an ISRC the other lacks.
    static func same(_ a: NowPlayingTrack?, _ b: NowPlayingTrack?) -> Bool {
        guard let a, let b else { return false }
        if a.identity == b.identity { return true }
        return TrackText.matchKey(artist: a.artist, title: a.title) == TrackText.matchKey(artist: b.artist, title: b.title)
    }
}

/// Chip order and prompt, frozen once the person starts so nothing reorders under a finger.
struct CaptureOrder: Equatable {
    var lenses: [MusicLens]
    var moods: [String]
    var prompt: String
}

/// A step the sheet is taking on its own (listening, reading a link), shown instead of the track.
enum CaptureFlow: Equatable {
    case idle
    case listening
    case readingLink
    case identifyFailed
    case linkFailed
    /// Resonote couldn't be reached while reading the link; it can be tried again.
    case linkUnreachable(url: String, message: String)
    /// A shared link arrived without a live session; it resolves after sign-in.
    case awaitingSignIn(String)

    /// Finding the song by listening or by reading a link, which another request mustn't cut short.
    var isFindingSong: Bool { self == .listening || self == .readingLink }
}

/// Words the capture sheet put in a draft on its own (the app went to the background),
/// so the next save replaces them instead of adding them twice.
struct CaptureAutosave: Equatable {
    var key: String
    var text: String
}

/// Work tied to the sheet's lifetime. The counter makes a repeated request a new task id.
enum CaptureWork: Equatable {
    case start
    case identify(Int)
    case link(String, Int)
    case resolveCurrent(Int)
    /// Ask the sources again before trusting the song on screen (a request from outside the app).
    case checkSources(Int)
}

/// Where the sheet goes when it closes with words still in it.
enum CaptureExit: Equatable {
    case close
    case search
}

enum CaptureField: Hashable {
    case note
    case mood
}

// MARK: - The note

/// The words being written. Kept in an observable object read only by the field (and,
/// through `hasText`, by whatever depends on whether there are words at all), so a
/// keystroke redraws the field and not the chips, header, and actions around it.
@Observable
final class CaptureNote {
    var text = "" {
        didSet {
            let has = !trimmed.isEmpty
            if has != hasText { hasText = has }
        }
    }
    private(set) var hasText = false

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The note's text field: the only view that reads every keystroke.
struct CaptureNoteField: View {
    @Bindable var note: CaptureNote
    var focus: FocusState<CaptureField?>.Binding
    var isFocused: Bool

    var body: some View {
        TextField("What did you notice?", text: $note.text, axis: .vertical)
            .lineLimit(3...8)
            .font(RN.Typography.prose)
            .focused(focus, equals: .note)
            .padding(RN.Space.m)
            .background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.input))
            .overlay(RoundedRectangle(cornerRadius: RN.Radius.input).strokeBorder(isFocused ? RN.Palette.lineStrong : RN.Palette.line))
    }
}

// MARK: - Views

/// The sheet's header: artwork (or a symbol) beside a title block of fixed height.
struct CaptureHeader: View {
    enum Art: Equatable {
        case artwork(String?)
        case symbol(String)
    }

    let art: Art
    let title: String
    let subtitle: String?
    let track: NowPlayingTrack?
    var isPlaceholder = false

    private static let artSize: CGFloat = 64

    var body: some View {
        HStack(alignment: .center, spacing: RN.Space.m) {
            artView
            NowTitleBlock(title: title, subtitle: subtitle) {
                if let track {
                    NowSourceText(track: track)
                } else {
                    Text(" ")
                }
            }
            .redacted(reason: isPlaceholder ? .placeholder : [])
            .accessibilityHidden(isPlaceholder)
        }
    }

    @ViewBuilder
    private var artView: some View {
        switch art {
        case .artwork(let url):
            ArtworkView(url, title: title, size: Self.artSize, cornerRadius: 8)
        case .symbol(let name):
            Image(systemName: name)
                .font(.title2)
                .foregroundStyle(RN.Palette.muted)
                .frame(width: Self.artSize, height: Self.artSize)
                .background(RN.Palette.paper3, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RN.Palette.line))
                .accessibilityHidden(true)
        }
    }
}

/// A titled group of toggle chips that wraps onto new lines.
struct CaptureChipGroup<Item: Hashable>: View {
    let title: String
    let items: [Item]
    let label: (Item) -> String
    let isSelected: (Item) -> Bool
    let toggle: (Item) -> Void
    /// A short note beside the title, laid out always and shown only when `showsHint`.
    var hint: String? = nil
    var showsHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: RN.Space.s) {
                CaptureSectionTitle(title)
                if let hint {
                    Spacer(minLength: 0)
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(RN.Palette.muted)
                        .opacity(showsHint ? 1 : 0)
                        .accessibilityHidden(!showsHint)
                }
            }
            FlowLayout {
                ForEach(items, id: \.self) { item in
                    Chip(label(item), isSelected: isSelected(item)) { toggle(item) }
                }
            }
        }
    }
}

struct CaptureSectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(RN.Palette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "+ your own word": adds a mood of the person's own to the mood chips.
struct CaptureMoodField: View {
    @Binding var text: String
    var focus: FocusState<CaptureField?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .imageScale(.small)
                .foregroundStyle(RN.Palette.muted)
                .accessibilityHidden(true)
            TextField("your own word", text: $text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .focused(focus, equals: .mood)
                .onSubmit(onSubmit)
                .accessibilityLabel("Add your own mood")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: 220, minHeight: 34, alignment: .leading)
        .overlay(Capsule().strokeBorder(RN.Palette.line))
    }
}

/// What to do when no song is known: listen, paste a link, or search.
struct CaptureFallbackOptions: View {
    let isListening: Bool
    /// The microphone is off for Resonote: offer the way to Settings instead of a listen that can't start.
    var microphoneDenied = false
    let onIdentify: () -> Void
    let onPaste: @MainActor @Sendable (URL) -> Void
    let onSearch: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.m) {
            if microphoneDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label("Allow the microphone in Settings", systemImage: "mic.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.outline)
                .accessibilityHint("Opens Resonote in the Settings app so it can listen")
            } else {
                Button(action: onIdentify) {
                    Label("Identify", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.outline)
                .disabled(isListening)
                .accessibilityHint("Listens for the song playing nearby")
            }

            HStack(spacing: RN.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paste a song link")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(RN.Palette.ink)
                    Text("Spotify, Apple Music, or YouTube Music")
                        .font(.caption)
                        .foregroundStyle(RN.Palette.muted)
                }
                Spacer(minLength: 0)
                PasteButton(payloadType: URL.self, onPaste: NowPaste.handler(onPaste))
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
            }
            .padding(.horizontal, RN.Space.m)
            .frame(minHeight: 52)
            .cardSurface()

            Button(action: onSearch) {
                Label("Search", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.outline)
        }
    }
}

/// What opened (or re-opened) the capture sheet.
struct CaptureRequest: Equatable {
    var preset: CapturePreset
    var startsListening: Bool
    var link: String?
}
