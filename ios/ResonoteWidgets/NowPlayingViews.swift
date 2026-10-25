import ResonoteKit
import SwiftUI
import UIKit
import WidgetKit

/// Picks the layout for the family. Paper background on the Home Screen; the system
/// removes it in tinted, clear, and Lock Screen modes.
struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        layout
            .widgetURL(entry.url)
            .containerBackground(for: .widget) {
                isAccessory ? Color.clear : RN.Palette.paper
            }
    }

    private var isAccessory: Bool {
        family == .accessoryCircular || family == .accessoryRectangular || family == .accessoryInline
    }

    @ViewBuilder private var layout: some View {
        switch family {
        case .systemMedium: MediumNowPlayingView(content: entry.content)
        case .accessoryRectangular: RectangularNowPlayingView(content: entry.content)
        case .accessoryCircular: CircularNowPlayingView(content: entry.content)
        case .accessoryInline: InlineNowPlayingView(content: entry.content)
        default: SmallNowPlayingView(content: entry.content)
        }
    }
}

// MARK: - Home Screen

private struct SmallNowPlayingView: View {
    let content: NowPlayingEntry.Content

    var body: some View {
        switch content {
        case .track(let card):
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: RN.Space.s) {
                    CoverArt(data: card.artwork, title: card.title)
                        .frame(width: 46, height: 46)
                    Spacer(minLength: 0)
                    WidgetEyebrow(card.status)
                        .multilineTextAlignment(.trailing)
                }
                Spacer(minLength: RN.Space.s)
                TrackTitle(card: card, size: 15, lines: 2)
                Spacer(minLength: RN.Space.s)
                WidgetAction(title: "Write about it", systemImage: "square.and.pencil")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .nothing:
            SmallMessageView(title: "Nothing playing", detail: nil, action: "Tap to identify", actionImage: "shazam.logo")
        case .signedOut:
            SmallMessageView(title: "Sign in to Resonote", detail: "Then note what you hear.", action: nil, actionImage: nil)
        }
    }
}

private struct SmallMessageView: View {
    let title: String
    let detail: String?
    let action: String?
    let actionImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecordGlyph()
                .frame(width: 40, height: 40)
            Spacer(minLength: RN.Space.s)
            Text(title)
                .font(RN.Typography.serif(16, relativeTo: .headline))
                .foregroundStyle(RN.Palette.ink)
                .lineLimit(2)
                .widgetAccentable()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            if let action, let actionImage {
                Spacer(minLength: RN.Space.s)
                WidgetAction(title: action, systemImage: actionImage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MediumNowPlayingView: View {
    let content: NowPlayingEntry.Content

    var body: some View {
        switch content {
        case .track(let card):
            HStack(spacing: 14) {
                CoverArt(data: card.artwork, title: card.title, cornerRadius: 10)
                    .aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: RN.Space.xs) {
                        WidgetEyebrow(card.status)
                        Spacer(minLength: 0)
                        RefreshButton()
                    }
                    TrackTitle(card: card, size: 17, lines: 1)
                    Spacer(minLength: RN.Space.xs)
                    Text(card.question)
                        .font(.caption)
                        .foregroundStyle(RN.Palette.prose)
                        .lineLimit(1)
                    if !card.suggestions.isEmpty {
                        SuggestionRow(chips: card.suggestions)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        case .nothing:
            MediumMessageView(title: "Nothing playing", detail: "Play something, or let Resonote listen.", action: "Tap to identify", actionImage: "shazam.logo", showsRefresh: true)
        case .signedOut:
            MediumMessageView(title: "Sign in to Resonote", detail: "Then the songs you play show up here, ready for a note.", action: nil, actionImage: nil, showsRefresh: false)
        }
    }
}

private struct MediumMessageView: View {
    let title: String
    let detail: String
    let action: String?
    let actionImage: String?
    let showsRefresh: Bool

    var body: some View {
        HStack(spacing: 14) {
            RecordGlyph()
                .aspectRatio(1, contentMode: .fit)
                .padding(6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: RN.Space.xs) {
                    WidgetEyebrow("Resonote")
                    Spacer(minLength: 0)
                    if showsRefresh { RefreshButton() }
                }
                Spacer(minLength: RN.Space.xs)
                Text(title)
                    .font(RN.Typography.serif(17, relativeTo: .headline))
                    .foregroundStyle(RN.Palette.ink)
                    .lineLimit(1)
                    .widgetAccentable()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(2)
                    .padding(.top, 2)
                Spacer(minLength: RN.Space.xs)
                if let action, let actionImage {
                    WidgetAction(title: action, systemImage: actionImage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Lock Screen

private struct RectangularNowPlayingView: View {
    let content: NowPlayingEntry.Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch content {
            case .track(let card):
                HStack(spacing: 4) {
                    Image(systemName: "music.note")
                    Text(card.title)
                }
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
                .invalidatableContent()
                if !card.artist.isEmpty {
                    Text(card.artist)
                        .font(.caption)
                        .lineLimit(1)
                        .invalidatableContent()
                }
                Text("Tap to note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .nothing:
                Text("Nothing playing")
                    .font(.headline)
                    .widgetAccentable()
                Text("Tap to identify")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .signedOut:
                Text("Resonote")
                    .font(.headline)
                    .widgetAccentable()
                Text("Sign in to Resonote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct CircularNowPlayingView: View {
    let content: NowPlayingEntry.Content

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            RecordGlyph(monochrome: true)
                .padding(7)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var label: String {
        switch content {
        case .track(let card): "Note \(card.title)"
        case .nothing: "Nothing playing. Identify a song"
        case .signedOut: "Sign in to Resonote"
        }
    }
}

private struct InlineNowPlayingView: View {
    let content: NowPlayingEntry.Content

    var body: some View {
        switch content {
        case .track(let card):
            Text(card.artist.isEmpty ? "♪ \(card.title)" : "♪ \(card.title) — \(card.artist)")
        case .nothing:
            Text("♪ Nothing playing")
        case .signedOut:
            Text("Sign in to Resonote")
        }
    }
}

// MARK: - Pieces

/// Title and artist; marked invalidatable so a refresh tap shows them as pending.
private struct TrackTitle: View {
    let card: TrackCard
    let size: CGFloat
    let lines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(card.title)
                .font(RN.Typography.serif(size, relativeTo: .headline))
                .foregroundStyle(RN.Palette.ink)
                .lineLimit(lines)
                .widgetAccentable()
            if !card.artist.isEmpty {
                Text(card.artist)
                    .font(.caption)
                    .foregroundStyle(RN.Palette.muted)
                    .lineLimit(1)
            }
        }
        .invalidatableContent()
        .accessibilityElement(children: .combine)
    }
}

/// The small uppercase label of the web's `.eyebrow`.
private struct WidgetEyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.heavy))
            .tracking(1)
            .foregroundStyle(RN.Palette.rustText)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }
}

/// The widget's invitation: what a tap does.
private struct WidgetAction: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(RN.Palette.rustText)
        .lineLimit(1)
        .widgetAccentable()
    }
}

/// Re-samples sources without opening the app; exempt from the reload budget.
private struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshNowPlayingIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RN.Palette.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }
}

/// Up to three tag chips, dropping from the end rather than truncating any.
private struct SuggestionRow: View {
    let chips: [SuggestionChip]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(chips.prefix(3))
            row(chips.prefix(2))
            row(chips.prefix(1))
        }
    }

    private func row(_ visible: ArraySlice<SuggestionChip>) -> some View {
        HStack(spacing: 6) {
            ForEach(visible) { chip in
                SuggestionChipLink(chip: chip)
            }
        }
    }
}

private struct SuggestionChipLink: View {
    let chip: SuggestionChip

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Link(destination: chip.url) {
            Text(chip.label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(minHeight: 24)
                .foregroundStyle(RN.Palette.ink)
                .background {
                    if renderingMode == .fullColor {
                        Capsule().fill(RN.Palette.fill)
                    }
                }
                .overlay(Capsule().strokeBorder(RN.Palette.lineStrong))
                .widgetAccentable()
        }
        .accessibilityLabel("Write about it: \(chip.label)")
    }
}

/// Album art with its size declared by the caller. Full color even in tinted
/// modes (Apple reserves that for media artwork); initials when there is none.
private struct CoverArt: View {
    let data: Data?
    let title: String
    var cornerRadius: CGFloat = RN.Radius.artwork + 2

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Color.clear
            .overlay {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .widgetAccentedRenderingMode(.fullColor)
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(RN.Palette.line))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var placeholder: some View {
        if renderingMode == .fullColor {
            ZStack {
                LinearGradient(colors: [RN.Palette.paper3, RN.Palette.paper2], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(Self.initials(title))
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .foregroundStyle(RN.Palette.muted)
            }
        } else {
            Image(systemName: "music.note")
                .font(.title3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func initials(_ title: String) -> String {
        title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

/// The Resonote record: a dark disc with a rust label, or line art on the Lock Screen.
private struct RecordGlyph: View {
    var monochrome = false

    @Environment(\.widgetRenderingMode) private var renderingMode

    private var usesLineArt: Bool { monochrome || renderingMode != .fullColor }

    var body: some View {
        ZStack {
            if usesLineArt {
                Circle().strokeBorder(lineWidth: 1.5)
                Circle().strokeBorder(lineWidth: 0.75).scaleEffect(0.74).opacity(0.6)
                Circle().scaleEffect(0.36)
            } else {
                Circle().fill(RN.Palette.disc)
                Circle().strokeBorder(RN.Palette.line, lineWidth: 1)
                ForEach([0.82, 0.68, 0.54], id: \.self) { scale in
                    Circle()
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                        .scaleEffect(scale)
                }
                Circle().fill(RN.Palette.rust).scaleEffect(0.36)
            }
            Circle()
                .scaleEffect(0.07)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
