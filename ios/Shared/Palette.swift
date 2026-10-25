import SwiftUI

/// Resonote's visual tokens, translated from the web app's `:root` in
/// src/app/globals.css. Shared by the app, widgets, and share extension.
nonisolated enum RN {
    nonisolated enum Palette {
        /// Page background.
        static let paper = Color(hex: 0x101113)
        /// Raised surfaces: cards, rows.
        static let paper2 = Color(hex: 0x17181B)
        /// Sheets, the editor surface.
        static let paper3 = Color(hex: 0x1D1F23)
        static let ink = Color(hex: 0xE9E7E2)
        static let muted = Color(hex: 0x9D9A94)
        /// Secondary prose.
        static let prose = Color(hex: 0xB3B1AB)
        static let line = Color(hex: 0xE9E7E2, opacity: 0.12)
        static let lineStrong = Color(hex: 0xE9E7E2, opacity: 0.26)
        static let fill = Color.white.opacity(0.045)
        /// The single accent: references, the vinyl label, selection.
        static let rust = Color(hex: 0xD4694A)
        /// The lighter rust used for eyebrows, errors, and "liked" labels.
        static let rustText = Color(hex: 0xE08A6D)
        /// Focus and information.
        static let blue = Color(hex: 0x85ACA3)
        /// Logo colors.
        static let disc = Color(hex: 0x181713)
        static let label = Color(hex: 0xF4EFE4)
    }

    nonisolated enum Radius {
        static let artwork: CGFloat = 4
        static let input: CGFloat = 8
        static let button: CGFloat = 10
        static let card: CGFloat = 12
        static let sheet: CGFloat = 14
    }

    nonisolated enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 36
        /// Horizontal page gutter on phones.
        static let gutter: CGFloat = 20
    }

    nonisolated enum Typography {
        /// Georgia ships with iOS; `relativeTo:` keeps Dynamic Type working.
        static func serif(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
            .custom("Georgia", size: size, relativeTo: style)
        }

        static let display = serif(34, relativeTo: .largeTitle)
        static let title = serif(24, relativeTo: .title2)
        static let headline = serif(19, relativeTo: .headline)
        /// Journal prose, like `.rich-document` on the web.
        static let prose = serif(18, relativeTo: .body)
        /// Section labels: about 11.5 pt at the default size, scaling with Dynamic Type.
        static let eyebrow = Font.system(.caption2, design: .default, weight: .heavy)
    }

    nonisolated enum Motion {
        static let quick = Animation.easeOut(duration: 0.16)
        static let settle = Animation.easeOut(duration: 0.18)
        /// The tonearm curve from the web player.
        static let arm = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.55)
        /// Seconds per vinyl revolution.
        static let spinPeriod: Double = 2.6
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
