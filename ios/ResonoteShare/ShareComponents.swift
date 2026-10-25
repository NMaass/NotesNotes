import SwiftUI
import UIKit

// Small local versions of the app's design system pieces. The app's DesignSystem
// isn't compiled into this target; these follow the same tokens from `RN`.

/// A pill toggle that inverts to ink on paper when selected (the app's `Chip`).
struct ShareChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .foregroundStyle(isSelected ? RN.Palette.paper : RN.Palette.ink)
                .background(isSelected ? RN.Palette.ink : RN.Palette.fill, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? RN.Palette.ink : RN.Palette.line))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }
}

/// A chip-shaped placeholder of final size, shown while suggestions load.
struct ShareChipPlaceholder: View {
    let width: CGFloat

    var body: some View {
        Capsule()
            .fill(RN.Palette.fill)
            .overlay(Capsule().strokeBorder(RN.Palette.line))
            .frame(width: width, height: 34)
            .accessibilityHidden(true)
    }
}

/// Wraps children onto new lines, left-aligned.
struct ShareFlowLayout: Layout {
    var spacing: CGFloat = RN.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Renders every candidate label in one cell and shows the active one, so the
/// button never changes size as its label changes (the app's `StableLabel`).
struct ShareStableLabel: View {
    let active: String
    let candidates: [String]

    var body: some View {
        ZStack {
            ForEach(candidates.contains(active) ? candidates : candidates + [active], id: \.self) { candidate in
                Text(candidate)
                    .opacity(candidate == active ? 1 : 0)
                    .accessibilityHidden(candidate != active)
            }
        }
    }
}

/// Solid ink button (the app's `.solid`).
struct ShareSolidButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .foregroundStyle(RN.Palette.paper)
            .background(RN.Palette.ink.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: RN.Radius.button))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Outlined button (the app's `.outline`).
struct ShareOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .foregroundStyle(RN.Palette.ink)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: RN.Radius.button))
            .overlay(RoundedRectangle(cornerRadius: RN.Radius.button).strokeBorder(RN.Palette.lineStrong))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A small heading above a group of chips.
struct ShareSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RN.Palette.prose)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Square cover art with its size fixed before anything loads; initials until then.
struct ShareArtwork: View {
    let url: URL?
    let title: String
    var size: CGFloat = 64

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ urlString: String?, title: String, size: CGFloat = 64) {
        url = urlString.flatMap(URL.init(string:))
        self.title = title
        self.size = size
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [RN.Palette.paper3, RN.Palette.paper2], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(initials)
                .font(.system(size: max(10, size * 0.3), weight: .semibold, design: .serif))
                .foregroundStyle(RN.Palette.muted)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: RN.Radius.artwork + 2))
        .overlay(RoundedRectangle(cornerRadius: RN.Radius.artwork + 2).strokeBorder(RN.Palette.line))
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let loaded = await Self.load(url, maxPixel: size * displayScale)
            withAnimation(reduceMotion ? nil : RN.Motion.quick) { image = loaded }
        }
    }

    private var initials: String {
        title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }

    private static func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let image = UIImage(data: data) else { return nil }
        let scale = min(1, maxPixel / max(image.size.width, image.size.height, 1))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return await image.byPreparingThumbnail(ofSize: target) ?? image
    }
}
