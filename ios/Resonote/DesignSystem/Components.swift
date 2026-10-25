import SwiftUI

/// Small uppercase label above a heading, like `.eyebrow` on the web.
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(RN.Typography.eyebrow)
            .tracking(1.4)
            .foregroundStyle(RN.Palette.rustText)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Eyebrow + serif heading for a page section.
struct SectionHeader: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.xs) {
            Eyebrow(eyebrow)
            Text(title)
                .font(RN.Typography.title)
                .foregroundStyle(RN.Palette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders every candidate label in one cell and shows only the active one, so a
/// control never changes size when its label changes (StableSwap on the web).
struct StableLabel: View {
    let active: String
    let candidates: [String]

    init(_ active: String, among candidates: [String]) {
        self.active = active
        self.candidates = candidates.contains(active) ? candidates : candidates + [active]
    }

    var body: some View {
        ZStack {
            ForEach(candidates, id: \.self) { candidate in
                Text(candidate)
                    .opacity(candidate == active ? 1 : 0)
                    .accessibilityHidden(candidate != active)
            }
        }
        .contentTransition(.identity)
    }
}

/// A pill toggle. Selected chips invert to ink on paper, as on the web. The haptic
/// answers the person's tap only, never a selection that changed because data arrived.
struct Chip: View {
    let title: String
    let isSelected: Bool
    var systemImage: String?
    let action: () -> Void

    @State private var taps = 0

    init(_ title: String, isSelected: Bool = false, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .foregroundStyle(isSelected ? RN.Palette.paper : RN.Palette.ink)
            .background(isSelected ? RN.Palette.ink : RN.Palette.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? RN.Palette.ink : RN.Palette.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: taps)
    }
}

/// Wraps children onto new lines, left-aligned — for chip rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = RN.Space.s
    var lineSpacing: CGFloat = RN.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
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
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// An error line whose height is reserved even when empty, so forms never jump.
struct ReservedErrorRow: View {
    let message: String?

    var body: some View {
        Text(message ?? " ")
            .font(.footnote)
            .foregroundStyle(RN.Palette.rustText)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .opacity(message == nil ? 0 : 1)
            .accessibilityHidden(message == nil)
    }
}

/// A calm empty state: a serif line and one sentence.
struct EmptyStateView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RN.Space.s) {
            Text(title)
                .font(RN.Typography.headline)
                .foregroundStyle(RN.Palette.ink)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(RN.Palette.muted)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.outline)
                    .fixedSize()
                    .padding(.top, RN.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RN.Space.l)
        .background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: RN.Radius.card).strokeBorder(RN.Palette.line))
    }
}

/// Solid ink button, the web's `.button--solid`.
struct SolidButtonStyle: ButtonStyle {
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

/// Outlined button, the web's `.button--outline`.
struct OutlineButtonStyle: ButtonStyle {
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

extension ButtonStyle where Self == SolidButtonStyle {
    static var solid: SolidButtonStyle { SolidButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}

extension View {
    /// The standard card surface.
    func cardSurface() -> some View {
        background(RN.Palette.paper2, in: RoundedRectangle(cornerRadius: RN.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: RN.Radius.card).strokeBorder(RN.Palette.line))
    }

    /// Page background and default text color.
    func paperBackground() -> some View {
        background(RN.Palette.paper.ignoresSafeArea())
            .foregroundStyle(RN.Palette.ink)
    }
}
